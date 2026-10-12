// The Mach side of the Metal host service (metal-sim-protocol.md §1–§2,
// iosurface-remote.md §2): served by the VMM's host task.
//
// - Every name (`serviceNames`) may point at the one `servicePort`.
// - A client opens a connection with the hand-shake 0x77303074: descriptor
//   0 is the connection port (a receive right the service keeps and
//   serves), descriptor 1 a send right of the client. On the connection of
//   type 0 that right is where completion events go (§2.1).
// - Requests are 0x10000000 messages with one `!CPX` dictionary; those
//   with a reply port get a 0x20000000 `!CPX` reply. Types 6 and 14 are
//   one-way.
// - Each connection is served in order on its own queue; the three
//   connections of a process run concurrently (pipeline creation on
//   connection 2 may be slow, submissions on connection 0 must not wait).
// - A connection ends when its port loses its senders; a process ends with
//   its last connection, and its objects are released.

import Foundation
import YcodeDarwinKernel
import YcodeXPC

public final class MetalHostService: @unchecked Sendable {
    /// `com.apple.metal.simulator` and the per-client names the macOS host
    /// registers (spec §1.1, launchd-sim.md §6.3). Registering only the
    /// first is enough: every process falls back to it.
    public static let serviceNames = [
        "com.apple.metal.simulator",
        "com.apple.metal.simulator.SpringBoard",
        "com.apple.metal.simulator.SBRendererService",
        "com.apple.metal.simulator.backboardd",
        "com.apple.metal.simulator.PineBoard",
        "com.apple.metal.simulator.HeadBoard",
        "com.apple.metal.simulator.Carousel",
    ]
    static let handshakeID: Int32 = 0x7730_3074
    static let requestID: Int32 = 0x1000_0000
    static let replyID: Int32 = 0x2000_0000
    static let eventID: Int32 = 0x1000_0000

    public let host: MachHostTask
    /// A receive right of the host task with a send right under the same name.
    public let servicePort: UInt32
    public let backend: MetalBackend
    let core: MetalHostCore
    private let portSet: UInt32
    private let log: (String) -> Void
    private let lock = NSLock()
    private var queues: [UInt32: DispatchQueue] = [:]
    private var stopping = false
    private var thread: Thread?

    /// `memory` resolves memory-entry rights (buffers' shared memory, data
    /// sent by memory entry); `surfaces` resolves IOSurface ports.
    public init(host: MachHostTask, backend: MetalBackend, memory: MetalGuestMemoryResolver?, surfaces: IOSurfaceResolver?,
                registryID: UInt64 = 0x1_0000_0059, log: @escaping (String) -> Void) throws {
        self.host = host
        self.backend = backend
        self.log = log
        core = MetalHostCore(backend: backend, memory: memory, surfaces: surfaces, registryID: registryID, log: log)
        servicePort = try host.makePort(sendRight: true, qlimit: 1024)
        portSet = try host.makePortSet()
        try host.addMember(servicePort, to: portSet)
        core.transport = self
    }

    public var statistics: MetalHostStatistics { core.statistics }

    public func start() {
        let t = Thread { [self] in run() }
        t.name = "ycode-metal"
        thread = t
        t.start()
    }

    public func stop() { lock.withLock { stopping = true } }

    private func run() {
        while !lock.withLock({ stopping }) {
            let m: MachHostReceivedMessage
            do {
                m = try host.receive(on: portSet, timeout: 200_000_000)
            } catch let e as MachHostError where e == .timedOut || e == .interrupted {
                continue
            } catch {
                if !lock.withLock({ stopping }) { log("metal: receive failed: \(error); stopping") }
                return
            }
            dispatch(m)
        }
    }

    // MARK: Messages

    func dispatch(_ m: MachHostReceivedMessage) {
        if m.localPort == servicePort {
            if m.id == Self.handshakeID { connect(m) } else { host.discard(m) }
            return
        }
        guard let queue = lock.withLock({ queues[m.localPort] }) else {
            host.discard(m)
            return
        }
        if m.id == MachNotify.noSenders {
            let port = m.localPort
            queue.async { [self] in close(port) }
        } else if m.id == Self.requestID {
            queue.async { [self] in request(m) }
        } else {
            host.discard(m)
        }
    }

    private func connect(_ m: MachHostReceivedMessage) {
        guard m.descriptors.count >= 2, case let .port(connection, type) = m.descriptors[0], type == 16,
              case let .port(client, _) = m.descriptors[1] else {
            log("metal: malformed hand-shake")
            host.discard(m)
            return
        }
        do {
            try host.addMember(connection, to: portSet)
            _ = try host.requestNotification(connection, id: MachNotify.noSenders, sync: 0, notifyPort: connection)
        } catch {
            log("metal: cannot serve connection \(connection): \(error)")
            try? host.destroyPort(connection)
            try? host.deallocate(client)
            return
        }
        core.connectionOpened(connection, clientPort: client)
        lock.withLock { queues[connection] = DispatchQueue(label: "ycode.metal.connection.\(connection)") }
    }

    private func close(_ port: UInt32) {
        lock.withLock { queues[port] = nil }
        let client = core.connectionClosed(port)
        try? host.destroyPort(port)
        if let client, MachPortName.isValid(client) { try? host.deallocate(client) }
    }

    private func request(_ m: MachHostReceivedMessage) {
        let wire: [XPCWireDescriptor] = m.descriptors.map {
            switch $0 {
            case let .port(name, type): return .port(name: name, disposition: type)
            case let .ool(data, _, _): return .ool(bytes: data)
            case let .oolPorts(names, type): return .oolPorts(names: names, disposition: type)
            case let .guardedPort(name, _, type): return .guardedPort(name: name, disposition: type)
            }
        }
        var outcome = MetalHostCore.Outcome(reply: [:])
        do {
            guard case let .dictionary(d) = try XPCWire.decode(body: m.body, descriptors: wire) else {
                throw XPCWireError.rootNotDictionary
            }
            outcome = core.handle(d, connection: m.localPort)
        } catch {
            log("metal: undecodable request: \(error)")
        }
        var replied = false
        if let reply = outcome.reply, MachPortName.isValid(m.replyPort) {
            do {
                let encoded = try XPCWire.encode(.dictionary(reply), magic: XPCWire.sim2hostMagic)
                try host.reply(to: m, id: Self.replyID, body: encoded.body)
                replied = true
            } catch {
                log("metal: reply failed: \(error)")
            }
        }
        // Drop every right the message brought except those the core keeps.
        var keep = outcome.retained
        var names: [UInt32] = []
        if !replied, MachPortName.isValid(m.replyPort) { names.append(m.replyPort) }
        for d in m.descriptors {
            switch d {
            case let .port(name, _), let .guardedPort(name, _, _): names.append(name)
            case let .oolPorts(list, _): names += list
            case .ool: break
            }
        }
        for name in names where MachPortName.isValid(name) {
            if let i = keep.firstIndex(of: name) {
                keep.remove(at: i)
                continue
            }
            dropRight(name)
        }
    }
}

extension MetalHostService: MetalHostTransport {
    func sendEvent(_ event: XPCDict, to port: UInt32) -> Bool {
        guard MachPortName.isValid(port), let encoded = try? XPCWire.encode(.dictionary(event), magic: XPCWire.sim2hostMagic) else {
            return false
        }
        let message = MachHostOutgoingMessage(remotePort: port, remoteDisposition: MachMsgType.copySend, id: Self.eventID,
                                              body: encoded.body)
        // The client drains its event port; wait for room, but not forever.
        for _ in 0..<50 {
            do {
                try host.send(message, timeout: 100_000_000)
                return true
            } catch let e as MachHostError where e.code == MachMsgReturn.sendTimedOut {
                if lock.withLock({ stopping }) { return false }
                continue
            } catch {
                return false
            }
        }
        log("metal: event port \(port) stayed full; event dropped")
        return false
    }

    /// Drops one reference of a right named in the host task. A send right
    /// to one of the host's own ports (an IOSurface port) drops only that
    /// send reference.
    func dropRight(_ name: UInt32) {
        guard MachPortName.isValid(name), let (type, _) = host.rights(of: name) else { return }
        if type & MachPortType.receive != 0 {
            if type & MachPortType.send != 0 { try? host.modRefs(name, right: MachPortRight.send, delta: -1) }
        } else {
            try? host.deallocate(name)
        }
    }
}
