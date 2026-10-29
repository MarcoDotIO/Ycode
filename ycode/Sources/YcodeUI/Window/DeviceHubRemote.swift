import AppKit
import YcodeDeviceModel
import YcodeDeviceUI
import YcodeDisplayStream

/// Device Hub's side of Ycode's remote simulator (`specs/ide/device-hub.md`
/// "Ycode implementation"): the display socket every device run serves, the
/// ssh forward that brings it to the Mac, and devices started from the hub
/// (Start / Shut Down / Restart) without an app.
extension RemoteSimulator {
    /// The display server's socket on the host: one per device directory
    /// under `<data>/display` (Ycode decision; a short path, Unix sockets
    /// allow about 100 bytes).
    public var displaySocketPath: String {
        "\(settings.dataDirectory)/display/\(target?.deviceDirectoryName ?? settings.deviceName).sock"
    }

    /// `--display-server unix:<socket>` for ycode-simd (`display-stream.md` §1).
    public var displayServerArguments: [String] { ["--display-server", "unix:" + displaySocketPath] }

    /// Start (the hub's status view, Device ▸ Start): the launcher boots the
    /// device with its display server and no app (as `ycode-sim-serve`
    /// does), printing the shell's pid first so Shut Down can signal it.
    public var startCommand: String {
        let q = Self.quote
        return "mkdir -p \(q("\(settings.dataDirectory)/display")); echo YCODE-REMOTE-PID $$; exec \(environmentPrefix)\(q(settings.simdPath))"
            + " --device \(q(remoteDevicePath)) --runtime-root \(q(runtimeRoot))"
            + (target?.deviceTypeArguments ?? []).map { " " + q($0) }.joined()
            + displayServerArguments.map { " " + q($0) }.joined()
            + Self.words(settings.additionalArguments).map { " " + q($0) }.joined()
            + cameraArguments.map { " " + q($0) }.joined()
    }

    /// `ssh -N -L <local socket>:<host socket> <destination>`: the display
    /// socket on the Mac (keys only; the forward fails rather than prompts).
    public func displayForwardArguments(localSocket: String) -> [String] {
        sshOptions + ["-N", "-o", "ExitOnForwardFailure=yes", "-o", "StreamLocalBindUnlink=yes", "-o", "ServerAliveInterval=15",
                      "-L", "\(localSocket):\(displaySocketPath)", settings.destination]
    }

    /// The device type's frame data (the viewer's table).
    public var frameSpec: DeviceFrameSpec {
        target.flatMap { DeviceFrameSpec.named(typeID: $0.deviceType.id) } ?? .iPhoneDuo
    }
}

/// One device's live display in the IDE: the ssh forward and the session
/// that the hub's canvas and the device's compact window show. The forward
/// is started again when it ends while the link is open; the session
/// reconnects by itself (`display-stream.md` §7).
@MainActor
public final class RemoteDisplayLink {
    public let session: DeviceLiveSession
    public let localSocket: String
    private let remote: RemoteSimulator?
    private var forward: Process?
    private var watchdog: Timer?
    private static var counter = 0

    /// A link to `remote`'s display socket through ssh.
    public init(remote: RemoteSimulator, name: String, os: String) {
        Self.counter += 1
        localSocket = (NSTemporaryDirectory() as NSString).appendingPathComponent("ycode-hub-\(getpid())-\(Self.counter).sock")
        self.remote = remote
        let hello = DisplayClientHello(client: "Ycode Device Hub", maxFPS: 60, encoding: "jpeg", quality: 80, downscale: 1)
        session = DeviceLiveSession(connection: ViewerConnection(address: .unix(localSocket), settings: hello), spec: remote.frameSpec)
        session.displayName = name
        session.osTitle = os
        startForward()
        session.start()
        watchdog = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { if self?.forward?.isRunning == false { self?.startForward() } }
        }
    }

    /// A link to a display socket the caller provides (tests, a local server).
    public init(address: DisplayAddress, spec: DeviceFrameSpec, name: String, os: String) {
        localSocket = ""
        remote = nil
        session = DeviceLiveSession(connection: ViewerConnection(address: address, settings: DisplayClientHello(client: "Ycode Device Hub")),
                                    spec: spec)
        session.displayName = name
        session.osTitle = os
        session.start()
    }

    private func startForward() {
        guard let remote else { return }
        unlink(localSocket)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: remote.settings.ssh)
        p.arguments = remote.displayForwardArguments(localSocket: localSocket)
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run(); forward = p } catch { forward = nil }
    }

    public func close() {
        watchdog?.invalidate()
        session.close()
        if let f = forward, f.isRunning { f.terminate() }
        forward = nil
        if !localSocket.isEmpty { unlink(localSocket) }
    }
}

/// Devices started from the hub (Start), keyed by device path. A started
/// device runs until Shut Down (with warm boot it is saved, as at a run's
/// Stop) or until Ycode quits (Ycode decision for "Stop simulators on
/// quit", device-hub.md §2.3 Q3). A run on a started device shuts it
/// down first (the launcher holds one run of a device at a time).
@MainActor
public final class RemoteDeviceSessions {
    public static let shared = RemoteDeviceSessions()
    public static let didChange = Notification.Name("YcodeRemoteDeviceSessionsDidChange")

    final class Entry {
        let remote: RemoteSimulator
        let process: StreamingProcess
        var pid: Int?
        var stopping = false
        var exited: [CheckedContinuation<Void, Never>] = []
        var done = false
        init(remote: RemoteSimulator, process: StreamingProcess) {
            self.remote = remote
            self.process = process
        }
    }

    private var entries: [String: Entry] = [:]
    private var quitObserver: NSObjectProtocol?

    /// Ycode quits: every started device is shut down (SIGINT to its
    /// launcher, which saves it with warm boot; Q3, Ycode decision). The
    /// signals are sent before the app exits; the saves finish on the host.
    func shutDownAllForQuit() {
        for e in entries.values where !e.done {
            if let pid = e.pid { _ = e.remote.signalRemote(pid, signal: "INT") } else { e.process.signal(SIGINT) }
        }
    }
    /// The launcher's lines (the console of the window that started it).
    public var output: (String) -> Void = { _ in }

    public func isRunning(_ remote: RemoteSimulator) -> Bool { entries[remote.remoteDevicePath] != nil }
    public var runningDevicePaths: Set<String> { Set(entries.keys) }

    /// Starts the device; false when it runs already or cannot be started.
    @discardableResult
    public func start(_ remote: RemoteSimulator) -> Bool {
        guard remote.settings.isConfigured, entries[remote.remoteDevicePath] == nil else { return false }
        if quitObserver == nil {
            quitObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { RemoteDeviceSessions.shared.shutDownAllForQuit() }
            }
        }
        let proc = StreamingProcess(executable: remote.settings.ssh, arguments: remote.sshArguments(remote.startCommand))
        let e = Entry(remote: remote, process: proc)
        entries[remote.remoteDevicePath] = e
        do {
            try proc.start(onLine: { [weak self, weak e] line in
                if let pid = RemoteSimulator.remotePID(line) { e?.pid = pid; return }
                self?.output(line)
            }, onExit: { [weak self, weak e] _ in
                guard let self, let e else { return }
                e.done = true
                if self.entries[e.remote.remoteDevicePath] === e { self.entries[e.remote.remoteDevicePath] = nil }
                e.exited.forEach { $0.resume() }
                e.exited = []
                NotificationCenter.default.post(name: Self.didChange, object: self)
            })
        } catch {
            entries[remote.remoteDevicePath] = nil
            return false
        }
        NotificationCenter.default.post(name: Self.didChange, object: self)
        return true
    }

    /// Shut Down (SIGINT to the launcher: with warm boot the device is
    /// saved) or Force Shut Down (SIGKILL to ycode-simd's shell: no save);
    /// returns when the launcher has ended (or after the stop grace).
    public func shutDown(_ remote: RemoteSimulator, force: Bool = false) async {
        guard let e = entries[remote.remoteDevicePath], !e.done else { return }
        e.stopping = true
        if let pid = e.pid {
            let status = await Task.detached { remote.signalRemote(pid, signal: force ? "KILL" : "INT") }.value
            if status != 0 { e.process.signal(SIGINT) }
        } else {
            e.process.signal(SIGINT)
        }
        let grace = remote.stopGrace
        Task { [weak e] in
            try? await Task.sleep(for: .seconds(grace))
            if let e, !e.done { e.process.signal(SIGINT) }
        }
        if !e.done { await withCheckedContinuation { e.exited.append($0) } }
    }

    /// Shuts every started device down (Ycode quits).
    public func shutDownAll() async {
        for e in entries.values { await shutDown(e.remote) }
    }
}

/// Launch options (the argument domain) for verification runs, so the hub
/// can be shown and captured without driving the menus:
/// `-YcodeOpenDeviceHub YES` opens Device Hub once the first workspace
/// window shows; `-YcodeDeviceHubSelect <name>` selects that row;
/// `-YcodeDeviceHubSearch <text>` types into the sidebar's search field;
/// `-YcodeDeviceHubStart YES` starts it; `-YcodeDeviceHubTab
/// settings|reports|info` picks the inspector tab;
/// `-YcodeDeviceHubCompact YES` opens its compact window once it runs.
@MainActor
enum DeviceHubLaunch {
    private static var done = false

    static func openIfAsked(_ wc: WorkspaceWindowController) {
        let d = UserDefaults.standard
        guard !done, d.bool(forKey: "YcodeOpenDeviceHub") else { return }
        done = true
        Task { @MainActor [weak wc] in
            try? await Task.sleep(for: .seconds(1.5))
            guard let wc else { return }
            let c = await wc.presentDevices()
            if let q = d.string(forKey: "YcodeDeviceHubSearch") { c.setSearch(q) }
            if let name = d.string(forKey: "YcodeDeviceHubSelect"), let i = c.rows.firstIndex(where: { $0.name == name }) { c.select(row: i) }
            switch d.string(forKey: "YcodeDeviceHubTab") {
            case "reports": c.selectInspectorTab(.reports)
            case "info": c.selectInspectorTab(.info)
            case "settings": c.selectInspectorTab(.settings)
            default: break
            }
            if d.bool(forKey: "YcodeDeviceHubStart"), let r = c.selected { await c.start(r)?.value }
            if d.bool(forKey: "YcodeDeviceHubCompact") {
                for _ in 0..<600 {
                    if let r = c.selected, r.state == "Booted", c.links[r.identifier]?.session.isLive == true { c.openInNewWindow(r); break }
                    try? await Task.sleep(for: .seconds(1))
                }
            }
        }
    }
}
