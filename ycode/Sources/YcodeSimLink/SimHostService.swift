// `ycode-simhost serve` (sim-link.md §6, §7): the simulator host's own
// service. One TCP listener (control and display connections, each its own
// handshake) and one UDP socket (the media channel). Every connection must
// finish the handshake as a trusted client (or as the one pairing a code
// allows) before anything it sends is read as a request; handshakes are
// limited per address (10 a minute) and in time (5 s).
//
// A display connection is a relay: the host connects to the device's
// display socket (`<home>/run/<device>.sock`) and copies the display
// stream both ways; with the media channel on, frame and frame-timing
// messages leave by UDP instead (§5).

import Crypto
import Foundation
import YcodeDisplayStream

public final class SimHostService: @unchecked Sendable {
    public let config: SimHostConfig
    public let store: LinkStore
    public let identity: LinkIdentity
    public let devices: SimHostDevices
    public var log: @Sendable (String) -> Void = { s in FileHandle.standardError.write(Data((s + "\n").utf8)) }

    private var listener: LinkListener?
    private var media: LinkDatagramSocket?
    private let lock = NSLock()
    private var sessions: [UInt32: MediaSession] = [:]
    private var attempts: [String: [Date]] = [:]
    private var stopped = false

    public init(config: SimHostConfig, store: LinkStore) throws {
        self.config = config
        self.store = store
        identity = try store.identity()
        devices = SimHostDevices(config: config)
    }

    public var controlPort: Int { listener?.port ?? config.controlPort }
    public var mediaPort: Int? { media?.port }

    /// Binds both sockets and starts serving.
    public func start() throws {
        devices.log = log
        let l = try LinkListener(host: config.listenHost, port: config.controlPort)
        listener = l
        do {
            let m = try LinkDatagramSocket(host: config.listenHost, port: config.mediaPort)
            media = m
            let t = Thread { [weak self] in self?.mediaLoop(m) }
            t.name = "simhost-media"
            t.qualityOfService = .userInteractive
            t.start()
        } catch {
            log("simhost: no media channel (UDP \(config.mediaPort)): \(error); frames stay on TCP")
        }
        log("simhost: \(config.name) listening on \(config.listenHost):\(l.port) (tcp)" + (media.map { ", media \($0.port) (udp)" } ?? "")
            + "; identity \(identity.fingerprint); \(store.peers().filter { $0.role == "client" }.count) trusted client(s)")
        let t = Thread { [weak self] in self?.acceptLoop(l) }
        t.name = "simhost-accept"
        t.start()
    }

    public func stop() {
        lock.withLock { stopped = true }
        listener?.close()
        media?.close()
        devices.stopAll()
    }

    // MARK: Accepting

    private func allowAttempt(_ who: String) -> Bool {
        lock.withLock {
            let now = Date()
            var list = (attempts[who] ?? []).filter { now.timeIntervalSince($0) < 60 }
            guard list.count < 10 else { attempts[who] = list; return false }
            list.append(now)
            attempts[who] = list
            return true
        }
    }

    private func acceptLoop(_ l: LinkListener) {
        while let (c, peer) = l.accept() {
            let who = LinkSockets.describe(peer)
            let ip = String(who.split(separator: ":").first ?? "")
            guard allowAttempt(ip) else { c.close(); continue }
            let t = Thread { [weak self] in self?.serve(c, who: who) }
            t.name = "simhost-conn"
            t.start()
        }
    }

    private func serve(_ c: DisplayConnection, who: String) {
        let accepted: SecureChannel.Accepted
        do {
            accepted = try SecureChannel.accept(c, identity: identity, pairingPSK: { Pairing.take(store: store) }, authorize: { key, hello, pairing in
                if pairing { return hello.purpose == "pair" }
                return store.trusted(key, role: "client") != nil && hello.purpose != "pair"
            })
        } catch {
            log("simhost: \(who): rejected (\(error))")
            c.close()
            return
        }
        let ch = accepted.channel
        let fp = LinkIdentity.fingerprint(ch.peerKey)
        if accepted.pairing {
            do {
                try store.addPeer(TrustedPeer(name: accepted.hello.client, publicKey: ch.peerKey, role: "client"))
                try ch.sendJSON(LinkWelcome(ok: true, host: config.name, version: LinkDefaults.version))
                log("simhost: \(who): paired with \"\(accepted.hello.client)\" (\(fp))")
            } catch {
                log("simhost: \(who): pairing failed: \(error)")
            }
            ch.close()
            return
        }
        log("simhost: \(who): \(accepted.hello.purpose) connection from \"\(accepted.hello.client)\" (\(fp))")
        switch accepted.hello.purpose {
        case "control": control(ch)
        case "display": display(ch, hello: accepted.hello, who: who)
        default:
            try? ch.sendJSON(LinkWelcome(ok: false, error: "unknown purpose"))
            ch.close()
        }
    }

    // MARK: Control

    private func control(_ ch: SecureChannel) {
        defer { ch.close() }
        guard (try? ch.sendJSON(LinkWelcome(ok: true, host: config.name, version: LinkDefaults.version))) != nil else { return }
        while let line = ch.receiveLine() {
            guard let req = try? JSONDecoder().decode(LinkRequest.self, from: Data(line)) else {
                try? ch.sendJSON(LinkResponse.failure("malformed request"))
                return
            }
            let r = handle(req, ch)
            guard (try? ch.sendJSON(r)) != nil else { return }
        }
    }

    func handle(_ req: LinkRequest, _ ch: SecureChannel) -> LinkResponse {
        switch req.op {
        case "info":
            var r = LinkResponse(ok: true)
            r.host = config.name
            r.deviceTypes = devices.deviceTypes()
            r.runtimes = Array(Set(config.runtimes.values)).sorted()
            return r
        case "devices":
            var r = LinkResponse(ok: true)
            r.devices = devices.list()
            return r
        case "create":
            guard let d = req.device else { return .failure("create needs a device") }
            do { try devices.create(d, type: req.deviceType ?? "iphone-duo") } catch { return .failure("\(error)") }
            return LinkResponse(ok: true, message: "created \(d)")
        case "boot", "run":
            guard let d = req.device else { return .failure("\(req.op) needs a device") }
            var bundle = req.bundleID
            if req.op == "run" {
                guard let app = req.app, isSafeName(app) else { return .failure("run needs an uploaded app") }
                if bundle == nil { bundle = Self.bundleID(appDirectory: config.appsDirectory + "/" + app) }
                guard bundle != nil else { return .failure("no CFBundleIdentifier in \(app)/Info.plist") }
            }
            do { try devices.start(d, app: req.op == "run" ? req.app : nil, bundleID: bundle, cold: req.cold == true) } catch { return .failure("\(error)") }
            var r = LinkResponse(ok: true, message: "\(d) starting")
            r.bundleID = bundle
            return r
        case "shutdown":
            guard let d = req.device else { return .failure("shutdown needs a device") }
            devices.stop(d)
            return LinkResponse(ok: true, message: "\(d) stopped")
        case "log":
            guard let d = req.device, isSafeName(d) else { return .failure("log needs a device") }
            var r = LinkResponse(ok: true)
            r.log = devices.logTail(d, lines: req.lines ?? 50)
            return r
        case "upload":
            guard let app = req.app, isSafeName(app), app.hasSuffix(".app"), let size = req.size, size > 0, size < 4 << 30 else {
                return .failure("upload needs an app name (X.app) and a size")
            }
            return upload(app, size: size, ch)
        default:
            return .failure("unknown op \(req.op)")
        }
    }

    /// Receives an archive of `size` bytes into `<apps>/<app>` (replacing it).
    private func upload(_ app: String, size: Int, _ ch: SecureChannel) -> LinkResponse {
        let dest = URL(fileURLWithPath: config.appsDirectory + "/" + app)
        let tmp = URL(fileURLWithPath: config.appsDirectory + "/." + app + ".upload")
        try? FileManager.default.createDirectory(atPath: config.appsDirectory, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: tmp)
        var buffer = ch.takeBuffered(max: size)
        var remaining = size - buffer.count
        let started = Date()
        do {
            try DirectoryArchive.extract(into: tmp, limit: size) { n in
                while buffer.count < n {
                    guard remaining > 0, let more = ch.receive() else { return nil }
                    remaining -= more.count
                    buffer += more
                }
                let out = Array(buffer.prefix(n))
                buffer.removeFirst(n)
                return out
            }
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: tmp, to: dest)
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            return .failure("upload: \(error)")
        }
        var r = LinkResponse(ok: true, message: String(format: "%@: %.1f MB in %.2f s", app, Double(size) / 1e6, Date().timeIntervalSince(started)))
        r.bundleID = Self.bundleID(appDirectory: dest.path)
        return r
    }

    static func bundleID(appDirectory: String) -> String? {
        guard let d = FileManager.default.contents(atPath: appDirectory + "/Info.plist"),
              let p = try? PropertyListSerialization.propertyList(from: d, options: [], format: nil) as? [String: Any] else { return nil }
        return p["CFBundleIdentifier"] as? String
    }

    // MARK: Display relay and media

    final class MediaSession: @unchecked Sendable {
        let id: UInt32
        var send: MediaCrypto
        var receive: MediaCrypto
        var client: sockaddr_in?
        var nextMessage: UInt32 = 0
        let lock = NSLock()
        init(id: UInt32, keys: (initiatorToResponder: SymmetricKey, responderToInitiator: SymmetricKey)) {
            self.id = id
            send = MediaCrypto(key: keys.responderToInitiator, session: id, direction: 1)
            receive = MediaCrypto(key: keys.initiatorToResponder, session: id, direction: 2)
        }
    }

    private func mediaLoop(_ m: LinkDatagramSocket) {
        while let (packet, from) = m.receive() {
            guard let h = MediaHeader(packet), h.direction == 2, let s = lock.withLock({ sessions[h.session] }) else { continue }
            s.lock.lock()
            let plain = s.receive.open(packet, expectDirection: 2)
            if let plain, plain.first == MediaPayload.clientHello { s.client = from }
            s.lock.unlock()
        }
    }

    private func display(_ ch: SecureChannel, hello: LinkHello, who: String) {
        guard let device = hello.device, isSafeName(device) else {
            try? ch.sendJSON(LinkWelcome(ok: false, error: "display needs a device"))
            ch.close()
            return
        }
        var session: MediaSession?
        if hello.media == true, media != nil {
            var id: UInt32 = 0
            lock.withLock {
                repeat { id = UInt32.random(in: 1...UInt32.max) } while sessions[id] != nil
                let s = MediaSession(id: id, keys: ch.mediaKeys)
                sessions[id] = s
                session = s
            }
        }
        defer {
            if let session { lock.withLock { sessions.removeValue(forKey: session.id) } }
            ch.close()
        }
        guard (try? ch.sendJSON(LinkWelcome(ok: true, host: config.name, version: LinkDefaults.version,
                                            mediaSession: session?.id, mediaPort: session == nil ? nil : media?.port))) != nil else { return }
        // The device's display socket (the client reconnects until it is up).
        guard let sim = try? DisplayConnection.connect(to: .unix(config.socketPath(device))) else {
            try? ch.send(DisplayMessage.notice("the device \(device) is not running").encoded())
            return
        }
        defer { sim.close() }
        let upstream = Thread {
            while let b = ch.receive() { do { try sim.send(b) } catch { break } }
            sim.close()
        }
        upstream.name = "simhost-up"
        upstream.start()
        var splitter = MessageSplitter()
        var udpMessages = 0, tcpBytes = 0
        let m = media
        while let b = sim.receive(max: 1 << 20) {
            splitter.append(b)
            var out: [UInt8] = []
            while let msg = splitter.next() {
                let type = msg[4]
                // A frame view goes with its frame (the headset viewer pairs them in order, xr-viewer.md §7).
                if let s = session, let m, type == DisplayMessageType.frame.rawValue || type == DisplayMessageType.frameTiming.rawValue
                    || type == DisplayMessageType.audio.rawValue || type == DisplayMessageType.frameView.rawValue,
                   let to = s.lock.withLock({ s.client }) {
                    s.lock.lock()
                    let id = s.nextMessage
                    s.nextMessage &+= 1
                    let packets = MediaPayload.fragments(of: msg, id: id).compactMap { try? s.send.seal($0) }
                    s.lock.unlock()
                    for p in packets { m.send(p, to: to) }
                    udpMessages += 1
                } else {
                    out += msg
                }
            }
            if !out.isEmpty {
                tcpBytes += out.count
                do { try ch.send(out) } catch { break }
            }
            if splitter.failed { break }
        }
        log("simhost: \(who): display of \(device) ended (\(udpMessages) messages by udp, \(tcpBytes / 1000) KB by tcp)")
    }
}

/// Splits a display stream into whole messages without decoding them (§2 framing).
public struct MessageSplitter: Sendable {
    private var buffer: [UInt8] = []
    private var start = 0
    public private(set) var failed = false

    public init() {}

    public mutating func append(_ b: [UInt8]) {
        if start > 0 && start == buffer.count { buffer.removeAll(keepingCapacity: true); start = 0 }
        buffer += b
    }

    /// The next message (length header included), nil when incomplete.
    public mutating func next() -> [UInt8]? {
        let avail = buffer.count - start
        guard avail >= 5 else { compact(); return nil }
        let n = Int(buffer[start]) | Int(buffer[start + 1]) << 8 | Int(buffer[start + 2]) << 16 | Int(buffer[start + 3]) << 24
        guard n >= 1, n <= DisplayStream.maxMessageSize else { failed = true; return nil }
        guard avail >= 4 + n else { compact(); return nil }
        let m = Array(buffer[start..<(start + 4 + n)])
        start += 4 + n
        return m
    }

    private mutating func compact() {
        if start > 1 << 20 { buffer.removeFirst(start); start = 0 }
    }
}
