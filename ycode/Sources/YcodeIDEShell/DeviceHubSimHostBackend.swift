import Foundation
import YcodeDisplayStream
import YcodeSimControl

/// Device Hub over the simulator hosts `ycrun` knows (`specs/ide/ycrun.md`
/// §5 and §11): the IDE's simulator host in the Linux IDE's defaults domain
/// (`ycode-ide`, the settings `ycrun remote setup` writes and Settings ▸
/// Components ▸ Simulator Host shows), ycrun's other hosts
/// (`~/.config/ycode/ycrun/hosts.json`), and this machine when Ycode's
/// simulator runs here (`SimPlacementPolicy`: arm64 Linux with `/dev/kvm`).
/// Commands go over ssh with a key (`SimShell`), or run here. Start boots a
/// device as `ycrun simctl boot` does (detached, its pid in
/// `<data>/ycrun/<device>.pid`), so ycrun sees it booted; Shut Down is
/// ycrun's SIGTERM to that pid, so a device ycrun booted stops from the hub
/// too. The live screen is the device's display socket: here directly, on a
/// host through an ssh forward (`ssh -N -L`, keys only) held while the
/// canvas shows it.
public final class DeviceHubSimHostBackend: DeviceHubBackend, @unchecked Sendable {
    public var environment: YcrunEnvironment
    /// How long Shut Down waits for the launcher to save and end.
    public var shutdownGrace = 150
    private let lock = NSLock()
    /// Hub host name → the host's context, from the last list.
    private var contexts: [String: SimHostContext] = [:]
    /// Device id → the forward's local socket and the function that ends it.
    private var forwards: [String: (socket: String, stop: () -> Void)] = [:]

    public init(environment: YcrunEnvironment = YcrunEnvironment()) {
        self.environment = environment
    }

    deinit { for f in forwards.values { f.stop(); unlink(f.socket) } }

    /// The hosts to list: this machine when the placement policy runs
    /// devices here and its launcher is in place, then every remote host.
    public func hostContexts() -> [SimHostContext] {
        var out: [SimHostContext] = []
        if SimPlacementPolicy.localSupport(environment.machine, macOSRunsLocally: environment.macOSRunsLocally).supported,
           let local = try? environment.context(.local),
           local.shell.run("[ -x \(shq(local.settings.simdPath)) ]", timeout: 10).ok {
            out.append(local)
        }
        for e in environment.store.remoteHosts() {
            out.append(SimHostContext(entry: e, settings: environment.store.settings(for: e), shell: environment.shell(for: e)))
        }
        return out
    }

    /// The hub's name for a host: "this computer" for this machine, else ycrun's name for it.
    public static func hubName(_ ctx: SimHostContext) -> String { ctx.entry.isLocal ? "this computer" : ctx.entry.name }

    public func list() -> [DeviceHubHost] {
        var out: [DeviceHubHost] = []
        var found: [String: SimHostContext] = [:]
        for ctx in hostContexts() {
            let name = Self.hubName(ctx)
            found[name] = ctx
            let devices = ctx.devices
            guard !devices.isEmpty else { out.append(DeviceHubHost(name: name, devices: [])); continue }
            let r = ctx.shell.run(ctx.stateCommand(devices), timeout: 60)
            // ssh's own failure (255): the host does not answer.
            if !ctx.entry.isLocal && r.status == 255 {
                out.append(DeviceHubHost(name: name, devices: [], offline: true))
                continue
            }
            let states = SimHostContext.parseStates(r.text)
            out.append(DeviceHubHost(name: name, devices: devices.map { d in
                DeviceHubDevice(host: name, name: d.name, deviceType: d.type.id, runtime: d.runtime.root,
                                state: Self.hubState(states[d.directory] ?? .shutdown))
            }))
        }
        lock.withLock { contexts = found }
        return out
    }

    /// ycrun's state in the hub's words (the link's: "running", "booting", "shutdown").
    public static func hubState(_ s: SimDeviceState) -> String {
        switch s {
        case .booted: "running"
        case .booting: "booting"
        case .shutdown: "shutdown"
        }
    }

    /// A device's host and ycrun's device.
    func resolve(_ d: DeviceHubDevice) -> (SimHostContext, SimDevice)? {
        guard let ctx = lock.withLock({ contexts[d.host] }) ?? hostContexts().first(where: { Self.hubName($0) == d.host }),
              let dev = ctx.devices.first(where: { $0.name == d.name }) else { return nil }
        return (ctx, dev)
    }

    public func boot(_ d: DeviceHubDevice) -> (Bool, String) {
        guard let (ctx, dev) = resolve(d) else { return (false, "\(d.name) is no longer set up on \(d.host).") }
        let r = ctx.shell.run(Simctl.startCommand(dev, ctx, extra: []), timeout: 60)
        if r.status == 3 { return (true, "\(d.name) is already running") }
        guard r.ok else { return (false, SimctlFormat.lastLines(r)) }
        return (true, "\(d.name) starting")
    }

    public func shutdown(_ d: DeviceHubDevice) -> (Bool, String) {
        endDisplay(d)
        guard let (ctx, dev) = resolve(d) else { return (false, "\(d.name) is no longer set up on \(d.host).") }
        let r = ctx.shell.run(YcrunDeviceFiles.stopCommand(pidFile: ctx.pidFile(dev), grace: shutdownGrace),
                              timeout: TimeInterval(shutdownGrace + 60))
        if r.status == 3 { return (false, Self.notOurs(d.name)) }
        guard r.ok else { return (false, SimctlFormat.lastLines(r)) }
        return (true, "\(d.name) stopped")
    }

    /// Shut Down of a device another program runs (a run, or the macOS IDE).
    public static func notOurs(_ name: String) -> String {
        "\(name) was started by a run or another program, not from Device Hub or ycrun: stop it there."
    }

    public func log(_ d: DeviceHubDevice, lines: Int) -> [String] {
        guard let (ctx, dev) = resolve(d) else { return [] }
        let r = ctx.shell.run("tail -n \(lines) \(shq(ctx.logFile(dev))) 2>/dev/null", timeout: 30)
        return r.text.split(whereSeparator: \.isNewline).map(String.init)
    }

    public func display(_ d: DeviceHubDevice) -> (@Sendable () throws -> DisplayTransport)? {
        guard let (ctx, dev) = resolve(d) else { return nil }
        let remote = ctx.remote(dev)
        if ctx.entry.isLocal {
            let path = remote.displaySocketPath
            return { try DisplayConnection.connect(to: .unix(path)) }
        }
        let id = d.id
        return { [weak self] in
            guard let self else { throw DisplaySocketError(message: "Device Hub closed") }
            let socket = try self.forward(id: id) {
                let local = NSTemporaryDirectory() + "ycode-hub-\(getpid())-\(UInt32.random(in: 0...UInt32.max)).sock"
                unlink(local)
                guard let stop = self.environment.background([self.environment.ssh] + remote.displayForwardArguments(localSocket: local)) else {
                    throw DisplaySocketError(message: "cannot start the ssh forward to \(ctx.shell.title)")
                }
                return (local, stop)
            }
            return try DisplayConnection.connect(to: .unix(socket))
        }
    }

    /// The device's forward, started on first use (the session reconnects
    /// every second while the device boots and while the forward comes up).
    func forward(id: String, make: () throws -> (String, () -> Void)) throws -> String {
        lock.lock()
        defer { lock.unlock() }
        if let f = forwards[id] { return f.socket }
        let (socket, stop) = try make()
        forwards[id] = (socket, stop)
        return socket
    }

    public func endDisplay(_ d: DeviceHubDevice) {
        guard let f = lock.withLock({ forwards.removeValue(forKey: d.id) }) else { return }
        f.stop()
        unlink(f.socket)
    }
}

/// Device Hub's hosts: those paired over Ycode's link and those ycrun knows
/// (ssh, or this machine). A ycrun host whose name a paired host already
/// has is listed as "<name> (ssh)".
public final class DeviceHubAllHostsBackend: DeviceHubBackend, @unchecked Sendable {
    public let link: any DeviceHubBackend
    public let simHosts: any DeviceHubBackend
    private let lock = NSLock()
    /// Hub host names of the ycrun hosts (renamed ones included) → ycrun's name.
    private var simHostNames: [String: String] = [:]

    public init(link: any DeviceHubBackend = DeviceHubLinkBackend(), simHosts: any DeviceHubBackend = DeviceHubSimHostBackend()) {
        self.link = link
        self.simHosts = simHosts
    }

    public func list() -> [DeviceHubHost] {
        let linked = link.list()
        let taken = Set(linked.map(\.name))
        var names: [String: String] = [:]
        let ycrun = simHosts.list().map { h -> DeviceHubHost in
            let shown = taken.contains(h.name) ? h.name + " (ssh)" : h.name
            names[shown] = h.name
            var out = h
            out.name = shown
            out.devices = h.devices.map { var d = $0; d.host = shown; return d }
            return out
        }
        lock.withLock { simHostNames = names }
        return linked + ycrun
    }

    /// The backend of a device, and the device as that backend names it.
    func route(_ d: DeviceHubDevice) -> (any DeviceHubBackend, DeviceHubDevice) {
        guard let original = lock.withLock({ simHostNames[d.host] }) else { return (link, d) }
        var o = d
        o.host = original
        return (simHosts, o)
    }

    public func boot(_ d: DeviceHubDevice) -> (Bool, String) { let (b, o) = route(d); return b.boot(o) }
    public func shutdown(_ d: DeviceHubDevice) -> (Bool, String) { let (b, o) = route(d); return b.shutdown(o) }
    public func display(_ d: DeviceHubDevice) -> (@Sendable () throws -> DisplayTransport)? { let (b, o) = route(d); return b.display(o) }
    public func log(_ d: DeviceHubDevice, lines: Int) -> [String] { let (b, o) = route(d); return b.log(o, lines: lines) }
    public func endDisplay(_ d: DeviceHubDevice) { let (b, o) = route(d); b.endDisplay(o) }
}
