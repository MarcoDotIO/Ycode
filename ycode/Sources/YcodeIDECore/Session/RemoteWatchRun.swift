import Foundation
import YcodeBuild

// Running watch apps on Ycode's remote simulators (`specs/simulator/device-pairing.md`
// P-9, §11.4, §13; `specs/ide/run.md` §Watch apps). Ycode's launcher installs
// and launches iOS apps with `ylaunch`, an iOS simulator build, so a watch
// app goes through the pairing agent that runs in every device
// (`device-pairing.md` §10.2 "Apps on a watch": `installApp`, `openApp`).
// The iOS app is installed first; its embedded watch app is not pushed
// through the phone (it fails in the reference, §11.4) but installed
// directly on the watch, and the guests then tell the phone themselves.

/// What a run of an app with a watch part does (P-9).
public struct RemoteWatchRunPlan: Equatable, Sendable {
    /// The iOS app (phone runs), with its embedded watch app.
    public var iOSApp: URL?
    /// The watch app to install on the watch.
    public var watchApp: URL
    /// Open the watch app once it is installed (the scheme is the watch
    /// app's); an iOS scheme's run only installs it.
    public var launchWatchApp: Bool

    public init(iOSApp: URL?, watchApp: URL, launchWatchApp: Bool) {
        self.iOSApp = iOSApp
        self.watchApp = watchApp
        self.launchWatchApp = launchWatchApp
    }
}

/// The error texts of a watch app run without a paired watch (`device-pairing.md`
/// §11.4, the reference's two messages).
public enum RemoteWatchRunError {
    public static let noPairedWatch = "The install is directed to a paired Apple Watch, but there isn't one."
    public static let selectPairedPhone = "Select an iPhone Run Destination with a paired Apple Watch."
}

extension RemoteSimulator {
    /// The watch app an iOS app embeds: `<App>.app/Watch/<Watch>.app`
    /// (`device-pairing.md` §5), the first in name order; nil when none.
    public static func embeddedWatchApp(in app: URL) -> URL? {
        let dir = app.appendingPathComponent("Watch")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.sorted().first { $0.hasSuffix(".app") }.map { dir.appendingPathComponent($0) }
    }

    /// Whether this simulator is a watch.
    public var isWatch: Bool { target?.isWatch ?? false }

    /// Where apps are staged in a device (a guest-readable DEV path, as
    /// `--install-app` stages its bundle): `<dev>/data/tmp/ycode-apps`.
    public var stagedAppsDirectory: String { "\(remoteDevicePath)/data/tmp/ycode-apps" }

    /// `mkdir -p` of the staging directory (the device has booted, so DEV exists).
    public var stageDirectoryCommand: String { "mkdir -p \(Self.quote(stagedAppsDirectory))" }

    /// rsync of an app into the device's staging directory.
    public func stageArguments(_ app: URL) -> [String] {
        ["-az", "--delete", "-e", ([settings.ssh] + sshOptions).joined(separator: " "),
         app.path + "/", "\(settings.destination):\(stagedAppsDirectory)/\(app.lastPathComponent)/"]
    }

    /// One request to the device's pairing agent through the running
    /// device's control socket: `ycode-sim --device DEV --control pairing
    /// agent <op> key=value…`. A `path` is a guest path: the device's guest
    /// path (`DEV/ycode-device-path`, the path its data first booted at)
    /// or, without that record, DEV itself, followed by the path inside DEV.
    public func agentCommand(_ op: String, _ args: [(String, String)] = [], devicePathRelative: (key: String, path: String)? = nil) -> String {
        let q = Self.quote
        var prefix = ""
        var words = args.map { q("\($0.0)=\($0.1)") }
        if let rel = devicePathRelative {
            prefix = "g=$(cat \(q(remoteDevicePath + "/ycode-device-path")) 2>/dev/null); [ -n \"$g\" ] || g=\(q(remoteDevicePath)); "
            words.append("\"\(rel.key)=$g\"\(q(rel.path))")
        }
        return prefix + "exec \(q(settings.simdPath)) --device \(q(remoteDevicePath)) --control pairing agent \(q(op))"
            + words.map { " " + $0 }.joined()
    }

    /// `installApp path=<guest path of the staged app>`.
    public func installAppCommand(_ app: URL) -> String {
        agentCommand("installApp", devicePathRelative: ("path", "/data/tmp/ycode-apps/\(app.lastPathComponent)"))
    }

    /// `openApp bundleID=<id>`.
    public func openAppCommand(bundleID: String) -> String { agentCommand("openApp", [("bundleID", bundleID)]) }

    /// `--control pairing state`: "ok <UDID>: agent up; …" once the device's
    /// pairing agent is connected.
    public var pairingStateCommand: String { controlCommand(["pairing", "state"]) }

    /// Whether a `pairing state` reply says the agent is up.
    public static func agentIsUp(stateReply: String) -> Bool { stateReply.contains("agent up") }

    /// Runs a shell command on the host: (status, output). Blocks.
    public func runRemote(_ command: String) -> (Int32, String) { runLocal(settings.ssh, sshArguments(command)) }

    /// Copies an app into the device's staging directory. Blocks.
    public func stageApp(_ app: URL) throws {
        let (m, mo) = runRemote(stageDirectoryCommand)
        guard m == 0 else { throw Simctl.Failure(description: "ssh mkdir failed (\(m)): \(mo)") }
        let (r, ro) = runLocal(settings.rsync, stageArguments(app))
        guard r == 0 else { throw Simctl.Failure(description: "rsync failed (\(r)): \(ro)") }
    }
}

extension WorkspaceSession {
    /// Builds a scheme of the workspace for a destination (a run on a phone
    /// with a paired watch builds the companion iOS app, whose build builds
    /// the embedded watch app for the watchOS simulator). The request is
    /// returned for the product lookup.
    public func build(scheme name: String, destination: Destination) async -> (BuildResult, BuildRequest) {
        let request = model.buildRequest(scheme: name, destination: destination, action: .build)
        let engine = self.engine
        let result = await performBuild(request, presentation: .init(action: .build, subject: name), start: engine.start)
        return (result, request)
    }

    /// A run that cannot start (no paired watch, §11.4): the text in the
    /// console and the activity "Run failed".
    public func failRemoteRun(_ text: String) {
        appendConsole("Ycode: \(text)\n")
        setActivity(.finished("Run failed"))
    }

    /// How long the IDE waits for a started watch's pairing agent (a first
    /// boot of a watch takes minutes; boot slots on the host may be taken).
    nonisolated public static var watchAgentWait: TimeInterval { Double(ProcessInfo.processInfo.environment["YCODE_WATCH_AGENT_WAIT_S"] ?? "") ?? 1800 }
    /// How long a paired run waits for the pair to connect before it
    /// installs the watch app anyway.
    nonisolated public static var pairConnectWait: TimeInterval { Double(ProcessInfo.processInfo.environment["YCODE_PAIR_CONNECT_WAIT_S"] ?? "") ?? 600 }

    /// Polls `check` every `interval` seconds until it is true, the time is
    /// up or `cancelled` is; returns the last value of `check`.
    func poll(_ seconds: TimeInterval, interval: Double = 5, cancelled: @MainActor () -> Bool = { false }, _ check: @MainActor () async -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while true {
            if await check() { return true }
            if cancelled() || Date() >= end { return false }
            try? await Task.sleep(for: .seconds(interval))
        }
    }

    /// Starts a watch from the IDE when it does not run yet (as Device Hub's
    /// Start: the launcher with its display server and no app). Returns
    /// whether this call started it.
    func startRemoteWatchIfNeeded(_ watch: RemoteSimulator) -> Bool {
        guard !RemoteDeviceSessions.shared.isRunning(watch) else { return false }
        RemoteDeviceSessions.shared.output = { [weak self] line in self?.appendConsole(line + "\n", kind: .debugger) }
        appendConsole("Ycode: starting \(watch.destination.name) on \(watch.settings.destination)\n", kind: .debugger)
        return RemoteDeviceSessions.shared.start(watch)
    }

    /// Installs a watch app directly on a running (or starting) watch through
    /// its pairing agent, and opens it when asked: waits for the agent, stages
    /// the bundle, `installApp` (retried while the guest is not ready), then
    /// `openApp`. (succeeded, message).
    public func installOnRemoteWatch(_ watchApp: URL, watch: RemoteSimulator, open: Bool,
                                     cancelled: @escaping @MainActor () -> Bool = { false }) async -> (Bool, String) {
        guard let app = AppBundle(url: watchApp) else { return (false, "\(watchApp.lastPathComponent) is not an application bundle") }
        let name = watch.destination.name
        appendConsole("Ycode: waiting for \(name) to be ready for apps\n", kind: .debugger)
        let up = await poll(Self.watchAgentWait, cancelled: cancelled) {
            let reply = await Task.detached { watch.control(["pairing", "state"]).1 }.value
            return RemoteSimulator.agentIsUp(stateReply: reply)
        }
        guard up else { return (false, cancelled() ? "stopped" : "\(name) did not become ready in \(Int(Self.watchAgentWait)) s") }
        do {
            try await Task.detached { try watch.stageApp(watchApp) }.value
        } catch {
            return (false, "the watch app could not be copied: \(error)")
        }
        appendConsole("Ycode: installing \(app.bundleID) on \(name) (directly on the watch)\n", kind: .debugger)
        var last = ""
        let installed = await poll(300, interval: 10, cancelled: cancelled) {
            let (s, out) = await Task.detached { watch.runRemote(watch.installAppCommand(watchApp)) }.value
            last = out.trimmingCharacters(in: .whitespacesAndNewlines)
            return s == 0 && last.hasPrefix("ok")
        }
        appendConsole("Ycode: installApp: \(last)\n", kind: .debugger)
        guard installed else { return (false, "installApp failed: \(last)") }
        guard open else { return (true, "installed \(app.bundleID)") }
        let opened = await poll(120, interval: 5, cancelled: cancelled) {
            let (s, out) = await Task.detached { watch.runRemote(watch.openAppCommand(bundleID: app.bundleID)) }.value
            last = out.trimmingCharacters(in: .whitespacesAndNewlines)
            return s == 0 && last.hasPrefix("ok")
        }
        appendConsole("Ycode: openApp: \(last)\n", kind: .debugger)
        return opened ? (true, "launched \(app.bundleID) on \(name)") : (false, "openApp failed: \(last)")
    }

    /// A watch app run on a watch alone (a watch destination): the watch is
    /// started when it does not run, the app installed and opened through
    /// the agent. The run lasts until Stop, which shuts the watch down (with
    /// warm boot it is saved), or until the watch ends.
    public func runOnRemoteWatch(app watchApp: URL, watch: RemoteSimulator) async {
        guard let app = AppBundle(url: watchApp) else {
            appendConsole("Ycode: \(watchApp.lastPathComponent) is not an application bundle.\n")
            return
        }
        guard watch.settings.isConfigured else {
            appendConsole("Ycode: set the remote simulator in Settings ▸ Components ▸ Simulator Host first.\n")
            return
        }
        let state = SimulatorRunState(target: .remote(destination: watch.settings.destination), app: app)
        state.remote = watch
        simulatorRun = state
        let device = watch.destination.name
        setActivity(.running(RemoteSimulator.status(.booting, app: app.executable, device: device)))
        _ = startRemoteWatchIfNeeded(watch)
        let (ok, message) = await installOnRemoteWatch(watchApp, watch: watch, open: true) { [weak state] in state?.stopRequested ?? true }
        guard ok else {
            appendConsole("Ycode: \(message)\n")
            if simulatorRun === state { simulatorRun = nil }
            setActivity(.finished(state.stopRequested ? WorkspaceSession.RunActivityText.finished(app.executable, on: device) : "Run failed"))
            return
        }
        appendConsole("Ycode: \(message)\n", kind: .debugger)
        setActivity(.running(RemoteSimulator.status(.running, app: app.executable, device: device)))
        // Until Stop or the watch's end.
        _ = await poll(1e9, interval: 0.5) { [weak state] in
            guard let state else { return true }
            return state.stopRequested || !RemoteDeviceSessions.shared.isRunning(watch)
        }
        if state.stopRequested, RemoteDeviceSessions.shared.isRunning(watch) {
            setActivity(.running(RemoteSimulator.stoppingStatus(app: app.executable, saves: watch.settings.warmBoot)))
            await RemoteDeviceSessions.shared.shutDown(watch)
        }
        appendConsole("Ycode Simulator stopped\n")
        if simulatorRun === state { simulatorRun = nil }
        setActivity(.finished(WorkspaceSession.RunActivityText.finished(app.executable, on: device)))
    }

    /// A run on a phone with a paired watch (P-9, §11.4): the iOS app is
    /// installed and launched on the phone as in every phone run, the watch
    /// started meanwhile when it does not run, and once the iOS app has
    /// launched (and the pair has connected) the watch app is installed
    /// directly on the watch, and opened when the scheme is the watch
    /// app's. Stop stops the phone's run; a watch this run started is shut
    /// down when the phone's run ends.
    public func runOnPairedRemoteSimulators(phone: RemoteSimulator, watch: RemoteSimulator, plan: RemoteWatchRunPlan) async {
        guard let iOSApp = plan.iOSApp, let ios = AppBundle(url: iOSApp) else {
            appendConsole("Ycode: no iOS app to install on \(phone.destination.name).\n")
            return
        }
        let startedWatch = startRemoteWatchIfNeeded(watch)
        await runOnRemoteSimulator(app: iOSApp, remote: phone)
        guard let state = simulatorRun, state.remote?.remoteDevicePath == phone.remoteDevicePath else {
            if startedWatch { await RemoteDeviceSessions.shared.shutDown(watch) }
            return
        }
        let watchName = watch.destination.name
        Task { [weak self, weak state] in
            guard let self else { return }
            let over: @MainActor () -> Bool = { [weak state] in state == nil || state?.stopRequested == true || self.simulatorRun !== state }
            // P-9: the iOS app first.
            let launched = await self.poll(1e9, interval: 1, cancelled: over) { self.console.contains("launched \(ios.bundleID)") }
            if launched {
                // The watch's appconduitd tells the phone about the app over the pair (§11.4).
                let connected = await self.poll(Self.pairConnectWait, interval: 5, cancelled: over) {
                    let pairs = await Task.detached { phone.readPairs() }.value
                    if let pairs { RemotePairsStore.shared.set(pairs) }
                    return pairs?.contains { $0.phoneDirectory == phone.deviceDirectoryName && $0.watchDirectory == watch.deviceDirectoryName && $0.connected } ?? false
                }
                if !connected, !over() { self.appendConsole("Ycode: \(watchName) is not connected to \(phone.destination.name) yet; installing the watch app anyway\n", kind: .debugger) }
                if !over() {
                    let (ok, message) = await self.installOnRemoteWatch(plan.watchApp, watch: watch, open: plan.launchWatchApp, cancelled: over)
                    self.appendConsole("Ycode: \(ok ? "" : "watch: ")\(message)\n", kind: .debugger)
                    if ok, plan.launchWatchApp, !over(), let w = AppBundle(url: plan.watchApp) {
                        self.setActivity(.running(RemoteSimulator.status(.running, app: w.executable, device: watchName)))
                    }
                }
            }
            // A watch this run started ends with the run.
            _ = await self.poll(1e9, interval: 1) { self.simulatorRun !== state || state == nil }
            if startedWatch, RemoteDeviceSessions.shared.isRunning(watch) {
                self.appendConsole("Ycode: shutting down \(watchName) (started for the run)\n", kind: .debugger)
                await RemoteDeviceSessions.shared.shutDown(watch)
            }
        }
    }
}
