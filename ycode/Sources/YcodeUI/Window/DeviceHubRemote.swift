import AppKit
import YcodeDeviceModel
import YcodeDeviceUI
import YcodeDisplayStream
import YcodeIDECore
import YcodeSubprocess

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
        do { try p.runWithSignalsUnblocked(); forward = p } catch { forward = nil }
    }

    public func close() {
        watchdog?.invalidate()
        session.close()
        if let f = forward, f.isRunning { f.terminate() }
        forward = nil
        if !localSocket.isEmpty { unlink(localSocket) }
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
