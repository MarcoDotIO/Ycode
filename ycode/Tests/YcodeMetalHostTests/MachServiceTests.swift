import Foundation
import Testing
import YcodeDarwinKernel
@testable import YcodeMetalHost
import YcodeXPC

/// The Mach side (spec §2.1, iosurface-remote.md §2): hand-shake messages,
/// `!CPX` requests and replies, events to the client's port, connection
/// end by no-senders. The "client" is the host task itself.
@Suite(.serialized) struct MachServiceTests {
    final class Client {
        let host: MachHostTask
        let service: MetalHostService
        init(host: MachHostTask, service: MetalHostService) { self.host = host; self.service = service }

        /// Opens a connection: descriptor 0 the connection port (MOVE_RECEIVE,
        /// we keep a send right), descriptor 1 our event port (MAKE_SEND).
        func open() throws -> (connection: UInt32, events: UInt32) {
            let connection = try host.makePort(sendRight: true)
            let events = try host.makePort(qlimit: 64)
            try host.send(MachHostOutgoingMessage(remotePort: service.servicePort, remoteDisposition: MachMsgType.copySend,
                                                  id: 0x7730_3074,
                                                  descriptors: [.port(name: connection, disposition: MachMsgType.moveReceive),
                                                                .port(name: events, disposition: MachMsgType.makeSend)]))
            return (connection, events)
        }

        /// A request with a reply port; returns the decoded reply.
        func request(_ connection: UInt32, _ d: XPCDict) throws -> XPCDict {
            let reply = try host.makePort()
            defer { try? host.destroyPort(reply) }
            let body = try XPCWire.encodePayload(.dictionary(d), magic: XPCWire.sim2hostMagic)
            try host.send(MachHostOutgoingMessage(remotePort: connection, remoteDisposition: MachMsgType.copySend, localPort: reply,
                                                  localDisposition: MachMsgType.makeSendOnce, id: 0x1000_0000, body: body))
            let m = try host.receive(on: reply, timeout: 5_000_000_000)
            #expect(m.id == 0x2000_0000)
            #expect(Array(m.body.prefix(4)) == [0x21, 0x43, 0x50, 0x58])  // "!CPX"
            guard case let .dictionary(r) = try XPCWire.decode(body: m.body, descriptors: []) else { throw XPCWireError.rootNotDictionary }
            return r
        }

        func oneWay(_ connection: UInt32, _ d: XPCDict) throws {
            let body = try XPCWire.encodePayload(.dictionary(d), magic: XPCWire.sim2hostMagic)
            try host.send(MachHostOutgoingMessage(remotePort: connection, remoteDisposition: MachMsgType.copySend, id: 0x1000_0000,
                                                  body: body))
        }

        func event(_ port: UInt32) throws -> XPCDict {
            let m = try host.receive(on: port, timeout: 5_000_000_000)
            #expect(m.id == 0x1000_0000 && !MachPortName.isValid(m.replyPort))
            guard case let .dictionary(r) = try XPCWire.decode(body: m.body, descriptors: []) else { throw XPCWireError.rootNotDictionary }
            return r
        }
    }

    @Test func handshakeRequestsEventsAndConnectionEnd() throws {
        let host = DarwinSystem().hostTask
        let backend = NullBackend()
        let service = try MetalHostService(host: host, backend: backend, memory: nil, surfaces: nil, log: { _ in })
        service.start()
        defer { service.stop() }
        let c = Client(host: host, service: service)

        var processRef: UInt64 = 0
        var connections: [(UInt32, UInt32)] = []
        for type in 0..<3 as Range<UInt64> {
            let (conn, events) = try c.open()
            connections.append((conn, events))
            let r = try c.request(conn, ["messageType": .uint64(0), "version": .uint64(1), "connectionType": .uint64(type),
                                         "processRef": .uint64(processRef)])
            #expect(r.keys == ["version", "processRef", "registryID", "hostFeatureProfile"])
            #expect(r["version"]?.uint64Value == 10 && r["hostFeatureProfile"]?.uint64Value == 10)
            if type == 0 { processRef = r["processRef"]?.uint64Value ?? 0 } else { #expect(r["processRef"]?.uint64Value == processRef) }
        }
        #expect(processRef != 0)
        let (c0, events0) = connections[0], c1 = connections[1].0

        // Op 37 on connection 0, a queue on connection 1.
        let limits = try c.request(c0, Build.message(12, Build.record(37) { $0.u32(0) }))
        #expect(limits["replyData"]?.dataValue.map { Build.u64($0, 3) } == 32768)
        let q = try c.request(c1, ["messageType": .uint64(7), "maxCommandBufferCount": .uint64(64)])
        #expect(q["commandQueueRef"]?.uint64Value == 1)

        // A one-way submission: events 100 then 101 arrive on the event port.
        let segment = Build.segment(kind: 2, [Build.record(307) { $0.u32(1) }], size: 1024)
        try c.oneWay(c0, ["messageType": .uint64(6), "commandQueue": .uint64(1), "commandBufferRef": .uint64(5),
                          "segments": .array([.data(segment)])])
        let e1 = try c.event(events0), e2 = try c.event(events0)
        #expect(e1["messageType"]?.uint64Value == 100 && e1["commandBufferRef"]?.uint64Value == 5 && e1["status"]?.uint64Value == 3)
        #expect(e2["messageType"]?.uint64Value == 101 && e2["status"]?.uint64Value == 4)

        // The client drops its send rights: the connections end, then the process.
        for (conn, _) in connections { try host.modRefs(conn, right: MachPortRight.send, delta: -1) }
        var waited = 0
        while service.statistics.processes != 0 && waited < 500 {
            usleep(10_000)
            waited += 1
        }
        #expect(service.statistics.processes == 0)
        #expect(backend.calls.contains(.submit(commandBufferRef: 5, passes: 1)))
    }

    /// The ordered end before exit (stage8-contract.md §12): the receive
    /// thread has stopped and the connection queues are idle when the
    /// backend is shut down; a second shutdown does nothing.
    @Test func shutdownStopsTheServiceBeforeTheBackend() throws {
        let host = DarwinSystem().hostTask
        let backend = NullBackend()
        let service = try MetalHostService(host: host, backend: backend, memory: nil, surfaces: nil, log: { _ in })
        final class Seen: @unchecked Sendable { var receivingAtBackendShutdown: Bool? }
        let seen = Seen()
        backend.onShutdown = { [unowned service] in
            seen.receivingAtBackendShutdown = service.receiving
        }
        service.start()
        let c = Client(host: host, service: service)
        let (conn, _) = try c.open()
        let r = try c.request(conn, ["messageType": .uint64(0), "version": .uint64(1), "connectionType": .uint64(0),
                                     "processRef": .uint64(0)])
        #expect(r["processRef"]?.uint64Value != 0)
        var waited = 0
        while !service.receiving && waited < 100 { usleep(1000); waited += 1 }
        #expect(service.receiving)

        let t0 = DispatchTime.now().uptimeNanoseconds
        #expect(service.shutdown(drainTimeout: 5))
        #expect(DispatchTime.now().uptimeNanoseconds - t0 < 2_000_000_000, "the receive thread stops within its 200 ms receive timeout")
        #expect(backend.shutdownCount == 1)
        #expect(seen.receivingAtBackendShutdown == false)
        #expect(!service.receiving)
        #expect(service.shutdown())
        #expect(backend.shutdownCount == 1, "idempotent")
    }
}
