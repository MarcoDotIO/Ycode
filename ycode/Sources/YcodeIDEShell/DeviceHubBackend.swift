import Foundation
import YcodeDeviceModel
import YcodeDisplayStream
import YcodeSimLink

/// One Ycode simulator as the Linux IDE's Device Hub lists it: a device of
/// a paired simulator host (`ycode sim remote pair`; a host on this
/// computer included), reached over Ycode's link (`sim-link.md`).
public struct DeviceHubDevice: Equatable, Sendable, Identifiable {
    /// The paired host's name.
    public var host: String
    /// The device's name on the host.
    public var name: String
    /// Ycode's device type id ("iphone-18-pro", "iphone-duo").
    public var deviceType: String
    /// The runtime root on the host (its folder names the OS).
    public var runtime: String
    /// The link's state: "shutdown", "booting", "running", "stopping".
    public var state: String
    /// The app a run started on it, if any.
    public var app: String?

    public init(host: String, name: String, deviceType: String, runtime: String, state: String, app: String? = nil) {
        (self.host, self.name, self.deviceType, self.runtime, self.state, self.app) = (host, name, deviceType, runtime, state, app)
    }

    public init(host: String, _ d: LinkDeviceInfo) {
        self.init(host: host, name: d.name, deviceType: d.deviceType, runtime: d.runtime, state: d.state, app: d.app)
    }

    public var id: String { host + "/" + name }
    /// The device type's frame (a placeholder phone for a type Ycode's frames do not know).
    public var spec: DeviceFrameSpec { DeviceFrameSpec.named(typeID: deviceType) ?? DeviceFrameSpec.placeholder(for: .phone) }
    /// The device type's name ("iPhone 18 Pro").
    public var typeName: String { DeviceFrameSpec.named(typeID: deviceType)?.name ?? deviceType }
    /// The platform and version from the runtime's folder ("…/iOS-27.1-24A94401/RuntimeRoot" → "iOS", "27.1").
    public var platform: String { Self.runtimeParts(runtime).platform }
    public var osVersion: String { Self.runtimeParts(runtime).version }
    /// Running or starting: its display can be shown.
    public var isRunning: Bool { state == "running" || state == "booting" }
    public var isStopped: Bool { state == "shutdown" }

    static func runtimeParts(_ runtime: String) -> (platform: String, version: String) {
        let url = URL(fileURLWithPath: runtime)
        let folder = url.lastPathComponent == "RuntimeRoot" ? url.deletingLastPathComponent().lastPathComponent : url.lastPathComponent
        let parts = folder.split(separator: "-").map(String.init)
        let platform = parts.first.flatMap { ["iOS", "watchOS", "tvOS", "visionOS", "xrOS"].contains($0) ? ($0 == "xrOS" ? "visionOS" : $0) : nil } ?? "iOS"
        let version = parts.dropFirst().first { $0.first?.isNumber == true && $0.contains(".") } ?? ""
        return (platform, version)
    }

    /// The sidebar's row (Ycode's shared hub model).
    public var hubDevice: HubDevice {
        let family = DeviceFrameSpec.named(typeID: deviceType)?.family ?? HubDevice.family(platform: platform, name: typeName, typeID: deviceType)
        return HubDevice(id: id, name: name, platform: platform, osVersion: osVersion, family: family, isSimulator: true,
                         model: typeName, isRunning: isRunning, isAvailable: true)
    }
}

/// What Device Hub does on a simulator host. The link's implementation is
/// `DeviceHubLinkBackend`; tests put a fake in its place.
public protocol DeviceHubBackend: Sendable {
    /// Every paired host's devices; a host that does not answer is listed with `offline`.
    func list() -> [DeviceHubHost]
    /// Starts a device (the link's `boot`): (succeeded, message).
    func boot(_ d: DeviceHubDevice) -> (Bool, String)
    /// Shuts a device down (the link's `shutdown`).
    func shutdown(_ d: DeviceHubDevice) -> (Bool, String)
    /// The connection of a device's display (DisplayStreamClient's `connect`); nil: none.
    func display(_ d: DeviceHubDevice) -> (@Sendable () throws -> DisplayTransport)?
    /// The last lines of the device's log on the host (why it stopped).
    func log(_ d: DeviceHubDevice, lines: Int) -> [String]
    /// The canvas no longer shows the device: what its display held (an ssh forward) can go.
    func endDisplay(_ d: DeviceHubDevice)
}

extension DeviceHubBackend {
    public func log(_ d: DeviceHubDevice, lines: Int) -> [String] { [] }
    public func endDisplay(_ d: DeviceHubDevice) {}
}

public struct DeviceHubHost: Equatable, Sendable {
    public var name: String
    public var devices: [DeviceHubDevice]
    public var offline: Bool
    public init(name: String, devices: [DeviceHubDevice], offline: Bool = false) {
        (self.name, self.devices, self.offline) = (name, devices, offline)
    }
}

/// Device Hub over Ycode's link (`sim-link.md`): the paired hosts in the
/// link's store, each asked for its devices with the `devices` request;
/// Start and Shut Down are `boot` and `shutdown`; the display is the
/// link's display channel (frames by UDP where the host offers them).
public struct DeviceHubLinkBackend: DeviceHubBackend {
    public var store: LinkStore
    public init(store: LinkStore = LinkStore()) { self.store = store }

    public func list() -> [DeviceHubHost] {
        guard let client = try? LinkClient(store: store) else { return [] }
        var out: [DeviceHubHost] = []
        for p in store.peers() where p.role == "host" {
            guard let h = LinkHost(p) else { continue }
            guard let c = try? client.control(h) else {
                out.append(DeviceHubHost(name: h.name, devices: [], offline: true))
                continue
            }
            defer { c.close() }
            guard let r = try? c.request(LinkRequest(op: "devices")), r.ok else {
                out.append(DeviceHubHost(name: h.name, devices: [], offline: true))
                continue
            }
            out.append(DeviceHubHost(name: h.name, devices: (r.devices ?? []).map { DeviceHubDevice(host: h.name, $0) }))
        }
        return out
    }

    func request(_ d: DeviceHubDevice, _ op: String) -> (Bool, String) {
        do {
            let client = try LinkClient(store: store)
            let c = try client.control(try client.host(named: d.host))
            defer { c.close() }
            let r = try c.request(LinkRequest(op: op, device: d.name))
            return r.ok ? (true, r.message ?? op) : (false, r.error ?? "\(op) failed")
        } catch {
            return (false, ShellRemoteRun.offlineMessage(host: d.host) + " (\(error))")
        }
    }

    public func log(_ d: DeviceHubDevice, lines: Int) -> [String] {
        guard let client = try? LinkClient(store: store), let h = try? client.host(named: d.host), let c = try? client.control(h) else { return [] }
        defer { c.close() }
        var req = LinkRequest(op: "log", device: d.name)
        req.lines = lines
        return (try? c.request(req))?.log ?? []
    }

    public func boot(_ d: DeviceHubDevice) -> (Bool, String) { request(d, "boot") }
    public func shutdown(_ d: DeviceHubDevice) -> (Bool, String) { request(d, "shutdown") }

    public func display(_ d: DeviceHubDevice) -> (@Sendable () throws -> DisplayTransport)? {
        guard let client = try? LinkClient(store: store), let host = try? client.host(named: d.host) else { return nil }
        let device = d.name
        return { try client.display(host, device: device, media: false) }
    }
}
