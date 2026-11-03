// The client side of the simulator link (sim-link.md §6): pairing, control
// requests, uploads, and the display transport the viewer reads (TCP for
// control messages; frames by UDP when the host offers the media channel).

import Crypto
import Foundation
import YcodeDisplayStream

public struct LinkHost: Sendable, Equatable {
    public var name: String
    public var host: String
    public var controlPort: Int
    public var mediaPort: Int
    public var publicKey: [UInt8]

    public init(name: String, host: String, controlPort: Int, mediaPort: Int, publicKey: [UInt8]) {
        (self.name, self.host, self.controlPort, self.mediaPort, self.publicKey) = (name, host, controlPort, mediaPort, publicKey)
    }

    public init?(_ p: TrustedPeer) {
        guard p.role == "host", let a = p.address, let k = p.keyBytes else { return nil }
        let (h, port) = SimHostConfig.splitHostPort(a, defaultPort: LinkDefaults.controlPort)
        self.init(name: p.name, host: h, controlPort: port, mediaPort: p.mediaPort ?? port + 1, publicKey: k)
    }
}

public final class LinkClient: @unchecked Sendable {
    public let store: LinkStore
    public let identity: LinkIdentity
    public let clientName: String

    public init(store: LinkStore = LinkStore(), clientName: String = ProcessInfo.processInfo.hostName) throws {
        self.store = store
        identity = try store.identity()
        self.clientName = clientName
    }

    /// Pairs with a host using its one-time code; trusts it as `name`.
    @discardableResult
    public func pair(host: String, port: Int, code: String, name: String, mediaPort: Int? = nil) throws -> TrustedPeer {
        let (ch, welcome) = try SecureChannel.connect(host: host, port: port, identity: identity, check: .pairing(code: code),
                                                     hello: LinkHello(purpose: "pair", client: clientName))
        ch.close()
        let peer = TrustedPeer(name: name, publicKey: ch.peerKey, role: "host", address: "\(host):\(port)", mediaPort: mediaPort)
        try store.addPeer(peer)
        _ = welcome
        return peer
    }

    public func host(named name: String?) throws -> LinkHost {
        guard let p = store.host(named: name), let h = LinkHost(p) else {
            let names = store.peers().filter { $0.role == "host" }.map(\.name)
            throw LinkError.refused(name.map { "no paired host \"\($0)\"" + (names.isEmpty ? "" : " (paired: \(names.joined(separator: ", ")))") }
                                    ?? (names.isEmpty ? "no paired host: run `ycode sim remote pair <host> <code>` first" : "several paired hosts: name one with --host (\(names.joined(separator: ", ")))"))
        }
        return h
    }

    // MARK: Control

    public final class Control: @unchecked Sendable {
        public let channel: SecureChannel
        public let welcome: LinkWelcome
        init(channel: SecureChannel, welcome: LinkWelcome) { (self.channel, self.welcome) = (channel, welcome) }

        public func request(_ r: LinkRequest) throws -> LinkResponse {
            try channel.sendJSON(r)
            guard let line = channel.receiveLine() else { throw LinkError.closed }
            guard let resp = try? JSONDecoder().decode(LinkResponse.self, from: Data(line)) else { throw LinkError.protocolViolation("response") }
            return resp
        }

        /// Uploads an app directory as `<apps>/<name>`; returns the host's answer.
        public func upload(_ app: URL, as name: String? = nil, progress: ((Int, Int) -> Void)? = nil) throws -> LinkResponse {
            let bytes = try DirectoryArchive.bytes(of: app)
            try channel.sendJSON(LinkRequest(op: "upload", app: name ?? app.lastPathComponent, size: bytes.count))
            var at = 0
            while at < bytes.count {
                let n = min(1 << 20, bytes.count - at)
                try channel.send(Array(bytes[at..<(at + n)]))
                at += n
                progress?(at, bytes.count)
            }
            guard let line = channel.receiveLine(), let resp = try? JSONDecoder().decode(LinkResponse.self, from: Data(line)) else {
                throw LinkError.closed
            }
            return resp
        }

        public func close() { channel.close() }
    }

    public func control(_ h: LinkHost) throws -> Control {
        let (ch, w) = try SecureChannel.connect(host: h.host, port: h.controlPort, identity: identity, check: .pinned(h.publicKey),
                                               hello: LinkHello(purpose: "control", client: clientName))
        return Control(channel: ch, welcome: w)
    }

    // MARK: Display

    /// A display transport to a device (DisplayStreamClient's `connect`).
    public func display(_ h: LinkHost, device: String, media: Bool) throws -> LinkDisplayTransport {
        let (ch, w) = try SecureChannel.connect(host: h.host, port: h.controlPort, identity: identity, check: .pinned(h.publicKey),
                                               hello: LinkHello(purpose: "display", device: device, client: clientName, media: media))
        return try LinkDisplayTransport(channel: ch, welcome: w, host: h.host, mediaPort: w.mediaPort ?? h.mediaPort)
    }
}

/// The display stream over the link: TCP for everything the host does not
/// send by UDP; frames reassembled from media packets, merged in arrival
/// order. A lost frame asks the host for a keyframe at once.
public final class LinkDisplayTransport: DisplayTransport, @unchecked Sendable {
    public let channel: SecureChannel
    public let mediaSession: UInt32?
    private var udp: LinkDatagramSocket?
    private var hostAddress: sockaddr_in?
    private let cond = NSCondition()
    private var queue: [[UInt8]] = []
    private var queued = 0
    private var ended = false
    /// The TCP reader waits past this many bytes, so that a slow reader slows the
    /// socket and its sender instead of a queue here growing without end
    /// (display-stream.md §4.2: run 8's 11 s).
    public static let queueLimit = 16 << 20
    private var send: MediaCrypto?
    private var receiveCrypto: MediaCrypto?
    /// Statistics: media packets, messages, losses.
    public private(set) var mediaPackets = 0, mediaMessages = 0, mediaLost = 0, rejected = 0

    init(channel: SecureChannel, welcome: LinkWelcome, host: String, mediaPort: Int) throws {
        self.channel = channel
        mediaSession = welcome.mediaSession
        if let session = welcome.mediaSession, let addr = LinkSockets.ipv4(host, mediaPort) {
            let u = try LinkDatagramSocket()
            udp = u
            hostAddress = addr
            send = MediaCrypto(key: channel.mediaKeys.initiatorToResponder, session: session, direction: 2)
            receiveCrypto = MediaCrypto(key: channel.mediaKeys.responderToInitiator, session: session, direction: 1)
            sayHello()
            let t = Thread { [weak self] in self?.mediaLoop() }
            t.name = "link-media"
            t.qualityOfService = .userInteractive
            t.start()
            let k = Thread { [weak self] in
                while let self, !self.isEnded { self.sayHello(); Thread.sleep(forTimeInterval: 1) }
            }
            k.name = "link-media-hello"
            k.start()
        }
        let r = Thread { [weak self] in self?.tcpLoop() }
        r.name = "link-tcp"
        r.qualityOfService = .userInteractive
        r.start()
    }

    var isEnded: Bool { cond.withLock { ended } }

    private func sayHello() {
        guard let udp, let hostAddress else { return }
        let packet = cond.withLock { try? send?.seal([MediaPayload.clientHello]) }
        if let packet { udp.send(packet, to: hostAddress) }
    }

    private func push(_ b: [UInt8], wait: Bool = false) {
        cond.withLock {
            while wait && queued > Self.queueLimit && !ended { cond.wait() }
            queue.append(b)
            queued += b.count
            cond.broadcast()
        }
    }

    private func tcpLoop() {
        var splitter = MessageSplitter()
        while let b = channel.receive() {
            splitter.append(b)
            while let m = splitter.next() { push(m, wait: true) }
            if splitter.failed { break }
        }
        cond.withLock { ended = true; cond.broadcast() }
        udp?.close()
    }

    private func mediaLoop() {
        guard let udp else { return }
        var r = MediaReassembler()
        while let (p, _) = udp.receive() {
            let now = UInt64(DispatchTime.now().uptimeNanoseconds)
            guard let plain = cond.withLock({ receiveCrypto?.open(p, expectDirection: 1) }) else { rejected += 1; continue }
            mediaPackets += 1
            var keyframe = false
            for o in r.add(plain, now: now) {
                switch o {
                case .message(let m): mediaMessages += 1; push(m)
                case .lost: mediaLost += 1; keyframe = true
                }
            }
            if keyframe { try? channel.send(DisplayMessage.keyframeRequest.encoded()) }
        }
    }

    public func send(_ bytes: [UInt8]) throws { try channel.send(bytes) }

    public func receive(max: Int) -> [UInt8]? {
        cond.withLock {
            while queue.isEmpty && !ended { cond.wait() }
            if queue.isEmpty { return nil }
            let b = queue.removeFirst()
            queued -= b.count
            cond.broadcast()
            return b
        }
    }

    public func close() {
        channel.close()
        udp?.close()
        cond.withLock { ended = true; cond.broadcast() }
    }
}
