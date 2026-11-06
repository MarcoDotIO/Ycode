// The host-side name `com.apple.CoreSimulator.SimIdentityService`
// (launchd-sim.md §6.3: the reference's host registers it; apsd is its only
// guest user, §6.4) as a Ycode host service with no identity to give
// (boot-profile.md §14.3).
//
// Why it exists: without the name, apsd's look-up fails, every
// certificate request fails at once with "Connection invalid", and apsd
// drops its courier connection and opens a new one, with a TLS handshake
// to the push servers, about three times a second for the whole run; each
// round wakes apsd's clients and logs about 200 messages (boot-profile.md
// §14.2). A host without an Apple-issued simulator identity (every Linux
// host) has no certificate to give, so Ycode's service accepts the
// connection and leaves each request unanswered: apsd's certificate
// refresh never completes and it does not reconnect.
//
// Wire: the XPC connection protocol Ycode's Metal host already serves
// (MetalHostService.swift): the hand-shake 0x77303074 brings the connection
// port (a receive right this service keeps) and a send right of the
// client; requests are 0x10000000 messages with one `!CPX` dictionary. The
// request's reply right is kept, never used and released when the
// connection ends (its port loses its senders), so the client sees neither
// a reply nor an error. The request's keys (names only) are logged once
// per distinct set. Written from Ycode's own specs; no Apple code.
//
// `YCODE_SIM_IDENTITY_SERVICE=0`: the name is not registered (the
// behaviour before this service).

import Foundation
import YcodeDarwinKernel
import YcodeXPC

public final class SimIdentityHostService: @unchecked Sendable {
    public static let serviceName = "com.apple.CoreSimulator.SimIdentityService"
    public static let disabled = getenv("YCODE_SIM_IDENTITY_SERVICE").map { String(cString: $0) == "0" } ?? false

    static let handshakeID: Int32 = 0x7730_3074
    static let requestID: Int32 = 0x1000_0000
    /// Requests kept unanswered at most; later ones are dropped (the client
    /// then sees its reply right die). A boot sends a handful.
    static let heldLimit = 256

    public let servicePort: UInt32
    private let host: MachHostTask
    private let log: (String) -> Void
    private let portSet: UInt32
    private let lock = NSLock()
    private var stopping = false
    /// Connection port → (client send right, reply rights held).
    private var connections: [UInt32: (client: UInt32, held: [UInt32])] = [:]
    private var heldCount = 0
    private var keySetsLogged: Set<[String]> = []
    private var limitLogged = false
    /// Statistics.
    public private(set) var requestCount = 0

    public init(host: MachHostTask, log: @escaping (String) -> Void) throws {
        self.host = host
        self.log = log
        servicePort = try host.makePort(sendRight: true, qlimit: 16)
        portSet = try host.makePortSet()
        try host.addMember(servicePort, to: portSet)
    }

    /// Requests now held unanswered.
    public var held: Int { lock.withLock { heldCount } }
    /// Connections open now.
    public var connectionCount: Int { lock.withLock { connections.count } }

    public func start() {
        let t = Thread { [self] in run() }
        t.name = "ycode-sim-identity"
        t.start()
    }

    public func stop() { lock.withLock { stopping = true } }

    private func run() {
        while !lock.withLock({ stopping }) {
            let m: MachHostReceivedMessage
            do {
                m = try host.receive(on: portSet, timeout: 200_000_000, tracked: true)
            } catch let e as MachHostError where e == .timedOut || e == .interrupted || e == .portChanged {
                continue
            } catch let e as MachHostError where e == MachHostError(MachMsgReturn.rcvInvalidName) {
                return  // the host task ended (the VMM is stopping)
            } catch {
                if !lock.withLock({ stopping }) { log("sim identity: receive failed: \(error); stopping") }
                return
            }
            handle(m)
            host.finishedMessage()
        }
    }

    func handle(_ m: MachHostReceivedMessage) {
        if m.localPort == servicePort {
            if m.id == Self.handshakeID { connect(m) } else { host.discard(m) }
            return
        }
        guard lock.withLock({ connections[m.localPort] != nil }) else {
            host.discard(m)
            return
        }
        if m.id == MachNotify.noSenders {
            close(m.localPort)
        } else if m.id == Self.requestID {
            hold(m)
        } else {
            host.discard(m)
        }
    }

    private func connect(_ m: MachHostReceivedMessage) {
        guard m.descriptors.count >= 2, case let .port(connection, type) = m.descriptors[0], type == MachMsgType.portReceive,
              case let .port(client, _) = m.descriptors[1] else {
            log("sim identity: malformed hand-shake")
            host.discard(m)
            return
        }
        do {
            try host.addMember(connection, to: portSet)
            _ = try host.requestNotification(connection, id: MachNotify.noSenders, sync: 0, notifyPort: connection)
        } catch {
            log("sim identity: cannot serve connection \(connection): \(error)")
            try? host.destroyPort(connection)
            try? host.deallocate(client)
            return
        }
        lock.withLock { connections[connection] = (client, []) }
    }

    /// Keeps the request's reply right (no answer, no error) and drops the
    /// rest of what it brought.
    private func hold(_ m: MachHostReceivedMessage) {
        let keys: [String] = {
            let wire: [XPCWireDescriptor] = m.descriptors.map {
                switch $0 {
                case let .port(name, type): return .port(name: name, disposition: type)
                case let .ool(data, _, _): return .ool(bytes: data)
                case let .oolPorts(names, type): return .oolPorts(names: names, disposition: type)
                case let .guardedPort(name, _, type): return .guardedPort(name: name, disposition: type)
                }
            }
            guard case let .dictionary(d)? = try? XPCWire.decode(body: m.body, descriptors: wire) else { return [] }
            return d.keys.sorted()
        }()
        let pid = m.sender?.pid ?? 0
        enum Outcome { case held, overLimit, noReply }
        let (outcome, firstKeys, firstOverLimit) = lock.withLock { () -> (Outcome, Bool, Bool) in
            requestCount += 1
            let first = keySetsLogged.insert(keys).inserted
            guard MachPortName.isValid(m.replyPort) else { return (.noReply, first, false) }
            guard heldCount < Self.heldLimit else {
                defer { limitLogged = true }
                return (.overLimit, first, !limitLogged)
            }
            connections[m.localPort]?.held.append(m.replyPort)
            heldCount += 1
            return (.held, first, false)
        }
        if firstKeys {
            log("sim identity: request from pid \(pid) (keys: \(keys.isEmpty ? "none" : keys.joined(separator: ", "))): "
                + "no simulator identity on this host, left unanswered")
        }
        if firstOverLimit { log("sim identity: \(Self.heldLimit) requests held; later ones are dropped") }
        var rest = m
        if outcome == .held { rest.replyPort = 0 }
        host.discard(rest)
    }

    // MARK: Snapshot (snapshot.md §2.6)

    /// A connection as a snapshot records it: the connection port (a
    /// receive right of the host task), the client's send right and the
    /// reply rights held unanswered.
    public struct ConnectionRecord: Equatable, Sendable {
        public var port: UInt32, client: UInt32, held: [UInt32]
        public init(port: UInt32, client: UInt32, held: [UInt32]) {
            self.port = port; self.client = client; self.held = held
        }
    }

    public var snapshotConnections: [ConnectionRecord] {
        lock.withLock {
            connections.map { ConnectionRecord(port: $0.key, client: $0.value.client, held: $0.value.held) }.sorted { $0.port < $1.port }
        }
    }

    /// After a restore: the host task holds the recorded rights under their
    /// recorded names again; the connections are served (and their requests
    /// stay unanswered) as before.
    public func restoreConnections(_ list: [ConnectionRecord]) {
        lock.withLock {
            for r in list {
                connections[r.port] = (r.client, r.held)
                heldCount += r.held.count
            }
        }
        for r in list { try? host.addMember(r.port, to: portSet) }
    }

    private func close(_ port: UInt32) {
        guard let c = lock.withLock({ () -> (client: UInt32, held: [UInt32])? in
            guard let c = connections.removeValue(forKey: port) else { return nil }
            heldCount -= c.held.count
            return c
        }) else { return }
        for r in c.held { try? host.deallocate(r) }
        try? host.destroyPort(port)
        if MachPortName.isValid(c.client) { try? host.deallocate(c.client) }
    }
}
