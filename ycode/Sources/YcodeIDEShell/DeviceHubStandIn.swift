import CYcodeCodec
import Foundation
import YcodeDeviceModel
import YcodeDisplayStream
import YcodeRemoteViewer

/// A stand-in simulator host for Device Hub's walks and tests, in-process:
/// its devices start and stop as a host's do (`boot` → "booting", then
/// "running"), and a running device serves a display stream on a Unix
/// socket of its own (`display-stream.md`: the hello, the status, zlib
/// frames, button presses, screenshots and the `settings` / `ui appearance`
/// commands). The picture is drawn here: a grid of squares over a gradient,
/// the "app" a full colour after a touch on a square, home again after Home,
/// dark after `ui appearance dark`. No device or runtime is involved: it lets
/// the Linux hub be exercised end to end on a machine without a simulator host
/// (`YCODE_IDE_HUB_STANDIN=1`, `ShellDriver+DeviceHub.swift`).
public final class DeviceHubStandInBackend: DeviceHubBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var devices: [DeviceHubDevice]
    private var servers: [String: StandInDisplay] = [:]
    public let directory: URL
    /// How long a boot takes.
    public var bootSeconds: Double

    public init(devices: [DeviceHubDevice] = DeviceHubStandInBackend.defaultDevices, bootSeconds: Double = 1) {
        self.devices = devices
        self.bootSeconds = bootSeconds
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ycode-hub-standin-\(getpid())-\(UInt32.random(in: 0...UInt32.max))")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    deinit { for s in servers.values { s.stop() } }

    public static let defaultDevices = [
        DeviceHubDevice(host: "stand-in", name: "iPhone 18 Pro", deviceType: "iphone-18-pro", runtime: "/stand-in/iOS-27.1-24A94401/RuntimeRoot", state: "shutdown"),
        DeviceHubDevice(host: "stand-in", name: "iPad (A16)", deviceType: "ipad-a16", runtime: "/stand-in/iOS-27.1-24A94401/RuntimeRoot", state: "shutdown"),
    ]

    public func list() -> [DeviceHubHost] { [DeviceHubHost(name: "stand-in", devices: lock.withLock { devices })] }

    private func set(_ id: String, _ state: String) {
        lock.withLock { for i in devices.indices where devices[i].id == id { devices[i].state = state } }
    }

    public func boot(_ d: DeviceHubDevice) -> (Bool, String) {
        let path = directory.appendingPathComponent("\(servers.count)-\(UInt32.random(in: 0...99999)).sock").path
        guard let server = try? StandInDisplay(path: path, device: d) else { return (false, "the stand-in display could not listen") }
        lock.withLock { servers[d.id] = server }
        set(d.id, "booting")
        let id = d.id
        DispatchQueue.global().asyncAfter(deadline: .now() + bootSeconds) { [weak self] in self?.set(id, "running") }
        return (true, "\(d.name) starting")
    }

    public func shutdown(_ d: DeviceHubDevice) -> (Bool, String) {
        let s = lock.withLock { servers.removeValue(forKey: d.id) }
        s?.stop()
        set(d.id, "shutdown")
        return (true, "\(d.name) stopped")
    }

    public func display(_ d: DeviceHubDevice) -> (@Sendable () throws -> DisplayTransport)? {
        guard let s = lock.withLock({ servers[d.id] }) else { return nil }
        let path = s.path
        return { try DisplayConnection.connect(to: .unix(path)) }
    }

    /// What the device last received (tests): "button home", "command ui appearance dark", "touch".
    public func received(_ id: String) -> [String] { lock.withLock { servers[id] }?.received ?? [] }
}

/// One stand-in device's display server.
final class StandInDisplay: @unchecked Sendable {
    let path: String
    let listener: DisplayListener
    let width: Int, height: Int, scale: Double
    let device: DeviceHubDevice
    private let lock = NSLock()
    private var connections: [DisplayConnection] = []
    private var dark = false
    private var inApp: Int?
    private var sequence: UInt64 = 0
    private(set) var received: [String] {
        get { lock.withLock { log } }
        set { lock.withLock { log = newValue } }
    }
    private var log: [String] = []

    init(path: String, device: DeviceHubDevice) throws {
        self.path = path
        self.device = device
        let panel = device.spec.panels[0]
        // A third of the panel's pixels, at a third of its scale: the same points.
        width = max(1, Int(panel.pixelWidth) / 3)
        height = max(1, Int(panel.pixelHeight) / 3)
        scale = max(0.5, Double(panel.scale) / 3)
        listener = try DisplayListener(address: .unix(path))
        Thread { [weak self] in self?.acceptLoop() }.start()
    }

    func stop() {
        listener.close()
        for c in lock.withLock({ connections }) { c.close() }
        unlink(path)
    }

    private func acceptLoop() {
        while let c = listener.accept() {
            lock.withLock { connections.append(c) }
            Thread { [weak self] in self?.serve(c) }.start()
        }
    }

    private func send(_ c: DisplayConnection, _ m: DisplayMessage) { try? c.send(m.encoded()) }

    private func serve(_ c: DisplayConnection) {
        var parser = DisplayMessageParser()
        var helloSent = false
        while let bytes = c.receive(max: 65536) {
            parser.append(bytes)
            while let m = try? parser.next() {
                switch m {
                case .clientHello:
                    guard !helloSent else { continue }
                    helloSent = true
                    var h = DisplayServerHello(deviceName: device.name, model: device.typeName, pixelWidth: width, pixelHeight: height, scale: scale,
                                               encodings: ["zlib"], touch: true, keyboard: true, buttons: ["home", "lock", "volumeUp", "volumeDown"],
                                               rotation: false)
                    h.deviceType = device.deviceType
                    h.osVersion = "\(device.platform) \(device.osVersion)"
                    send(c, .hello(h))
                    send(c, .status(DisplayStatus(phase: "live", uptimeMilliseconds: 1000, guestFrames: 1)))
                    sendFrame(c)
                case .input(.button(_, let b, let down)):
                    guard down else { continue }
                    note("button \(b.name)")
                    if b == .home { lock.withLock { inApp = nil } }
                    sendFrame(c)
                case .input(.touch(_, let contacts)):
                    note("touch")
                    if let t = contacts.first, t.phase == .ended {
                        // Which square the touch ended on (points → the grid).
                        let col = Int(Double(t.x) / (Double(width) / scale) * 4), row = Int(Double(t.y) / (Double(height) / scale) * 6)
                        lock.withLock { inApp = max(0, min(23, row * 4 + col)) }
                        sendFrame(c)
                    }
                case .keyframeRequest: sendFrame(c)
                case .screenshotRequest(let token):
                    send(c, .screenshot(token: token, png: PNGWriter.encode(rgba: rgba(), width: width, height: height) ?? []))
                case .command(let token, let text):
                    note("command \(text)")
                    send(c, .commandReply(token: token, text: answer(text)))
                    sendFrame(c)
                case .ping(let token): send(c, .pong(token: token, serverNanoseconds: UInt64(DispatchTime.now().uptimeNanoseconds)))
                default: break
                }
            }
        }
        c.close()
    }

    private func note(_ s: String) {
        lock.withLock { log.append(s) }
    }

    private func answer(_ text: String) -> String {
        let w = text.split(separator: " ").map(String.init)
        switch w.first {
        case "settings": return "ok appearance \(lock.withLock { dark } ? "dark" : "light")\nreduce-motion off\nincrease-contrast off\nvolume 60\noutput system\ninput system"
        case "ui" where w.count >= 3 && w[1] == "appearance":
            lock.withLock { dark = w[2] == "dark" }
            return "ok appearance \(w[2])"
        case "accessibility" where w.count >= 3: return "ok \(w[1]) \(w[2])"
        default: return "error: the stand-in host does not know \(w.first ?? "")"
        }
    }

    /// The picture: a gradient with a 4 × 6 grid of squares (home), or one colour (an app).
    func rgba() -> [UInt8] {
        let (dark, app) = lock.withLock { (self.dark, self.inApp) }
        var px = [UInt8](repeating: 255, count: width * height * 4)
        let palette: [(UInt8, UInt8, UInt8)] = [(255, 69, 58), (255, 159, 10), (48, 209, 88), (10, 132, 255), (191, 90, 242), (255, 55, 95)]
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                var c: (UInt8, UInt8, UInt8)
                if let app {
                    c = palette[app % palette.count]
                } else {
                    let t = Double(y) / Double(height)
                    c = dark ? (UInt8(20 + 30 * t), UInt8(24 + 20 * t), UInt8(48 + 40 * t)) : (UInt8(120 + 100 * t), UInt8(170 + 60 * t), UInt8(235))
                    let cw = width / 4, ch = height / 6
                    let cx = x % cw, cy = y % ch
                    if cx > cw / 5, cx < cw * 4 / 5, cy > ch / 5, cy < ch * 3 / 5 {
                        c = palette[(y / ch * 4 + x / cw) % palette.count]
                    }
                }
                px[i] = c.0; px[i + 1] = c.1; px[i + 2] = c.2
            }
        }
        return px
    }

    private func sendFrame(_ c: DisplayConnection) {
        let px = rgba()
        // zlib of BGRA rows.
        var bgra = px
        for i in stride(from: 0, to: bgra.count, by: 4) { bgra.swapAt(i, i + 2) }
        var out = [UInt8](repeating: 0, count: ycodec_zlib_bound(bgra.count))
        var n = out.count
        guard ycodec_zlib_compress(bgra, bgra.count, 1, &out, &n) == 0 else { return }
        let seq = lock.withLock { sequence += 1; return sequence }
        let f = DisplayFrame(sequence: seq, guestFrame: seq, serverNanoseconds: UInt64(DispatchTime.now().uptimeNanoseconds), inputSequence: 0,
                             width: width, height: height, encoding: .zlibBGRA, isFull: true,
                             tiles: [DisplayTile(x: 0, y: 0, width: width, height: height, data: Array(out.prefix(n)))])
        send(c, .frame(f))
    }
}
