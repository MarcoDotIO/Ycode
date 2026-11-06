import Foundation
import Testing
import YcodeDarwinKernel
@testable import YcodeHostServices
import YcodeXPC

/// The simulator identity service (SimIdentityHostService.swift,
/// boot-profile.md §14.3): a connection is accepted, a request gets
/// neither a reply nor a dead reply right while the connection lives, and
/// the held reply rights go when the connection ends. The "client" is the
/// host task itself.
@Suite(.serialized) struct SimIdentityHostServiceTests {
    @Test func requestsStayUnansweredUntilTheConnectionEnds() throws {
        let host = DarwinSystem().hostTask
        var lines: [String] = []
        let linesLock = NSLock()
        let service = try SimIdentityHostService(host: host, log: { l in linesLock.withLock { lines.append(l) } })
        service.start()
        defer { service.stop() }

        // The hand-shake: the connection port (we keep a send right) and our event port.
        let connection = try host.makePort(sendRight: true)
        let events = try host.makePort(qlimit: 8)
        try host.send(MachHostOutgoingMessage(remotePort: service.servicePort, remoteDisposition: MachMsgType.copySend,
                                              id: 0x7730_3074,
                                              descriptors: [.port(name: connection, disposition: MachMsgType.moveReceive),
                                                            .port(name: events, disposition: MachMsgType.makeSend)]))
        // Two requests with reply ports.
        var replies: [UInt32] = []
        for i in 0..<2 {
            let reply = try host.makePort()
            replies.append(reply)
            let body = try XPCWire.encodePayload(.dictionary(["request": .uint64(UInt64(i)), "client": .string("test")]))
            try host.send(MachHostOutgoingMessage(remotePort: connection, remoteDisposition: MachMsgType.copySend, localPort: reply,
                                                  localDisposition: MachMsgType.makeSendOnce, id: 0x1000_0000, body: body))
        }
        var waited = 0
        while service.held < 2 && waited < 500 {
            usleep(10_000)
            waited += 1
        }
        #expect(service.held == 2 && service.connectionCount == 1 && service.requestCount == 2)
        // No reply and no send-once notification while the connection lives.
        for r in replies {
            #expect(throws: MachHostError.self) { _ = try host.receive(on: r, timeout: 100_000_000) }
        }
        // One log line for the one key set, with the key names only.
        #expect(linesLock.withLock { lines.filter { $0.contains("keys: client, request") }.count } == 1)

        // The client drops its send right: the connection ends and the held
        // reply rights are released (each reply port gets its send-once notification).
        try host.modRefs(connection, right: MachPortRight.send, delta: -1)
        waited = 0
        while (service.connectionCount != 0 || service.held != 0) && waited < 500 {
            usleep(10_000)
            waited += 1
        }
        #expect(service.connectionCount == 0 && service.held == 0)
        for r in replies {
            let m = try host.receive(on: r, timeout: 5_000_000_000)
            #expect(m.id == MachNotify.sendOnce)
            try? host.destroyPort(r)
        }
        try? host.destroyPort(events)
    }

    @Test func aRestoredServiceKeepsTheConnectionsAndHeldRequests() throws {
        let host = DarwinSystem().hostTask
        let first = try SimIdentityHostService(host: host, log: { _ in })
        first.start()
        let connection = try host.makePort(sendRight: true)
        let events = try host.makePort(qlimit: 8)
        defer { try? host.destroyPort(events) }
        try host.send(MachHostOutgoingMessage(remotePort: first.servicePort, remoteDisposition: MachMsgType.copySend,
                                              id: 0x7730_3074,
                                              descriptors: [.port(name: connection, disposition: MachMsgType.moveReceive),
                                                            .port(name: events, disposition: MachMsgType.makeSend)]))
        let reply = try host.makePort()
        defer { try? host.destroyPort(reply) }
        try host.send(MachHostOutgoingMessage(remotePort: connection, remoteDisposition: MachMsgType.copySend, localPort: reply,
                                              localDisposition: MachMsgType.makeSendOnce, id: 0x1000_0000,
                                              body: try XPCWire.encodePayload(.dictionary(["a": .bool(true)]))))
        var waited = 0
        while first.held < 1 && waited < 500 {
            usleep(10_000)
            waited += 1
        }
        let records = first.snapshotConnections
        #expect(records.count == 1 && records[0].port == connection && records[0].held.count == 1)
        first.stop()
        usleep(300_000)  // its receive loop ends within one 200 ms timeout

        let second = try SimIdentityHostService(host: host, log: { _ in })
        second.restoreConnections(records)
        second.start()
        defer { second.stop() }
        #expect(second.connectionCount == 1 && second.held == 1)
        // Still no answer on the restored connection; the end releases the held right.
        #expect(throws: MachHostError.self) { _ = try host.receive(on: reply, timeout: 100_000_000) }
        try host.modRefs(connection, right: MachPortRight.send, delta: -1)
        #expect(try host.receive(on: reply, timeout: 5_000_000_000).id == MachNotify.sendOnce)
        #expect(second.held == 0)
    }

    @Test func messagesOnTheServicePortOtherThanTheHandshakeAreDropped() throws {
        let host = DarwinSystem().hostTask
        let service = try SimIdentityHostService(host: host, log: { _ in })
        service.start()
        defer { service.stop() }
        let reply = try host.makePort()
        defer { try? host.destroyPort(reply) }
        try host.send(MachHostOutgoingMessage(remotePort: service.servicePort, remoteDisposition: MachMsgType.copySend, localPort: reply,
                                              localDisposition: MachMsgType.makeSendOnce, id: 0x1000_0000, body: []))
        // The reply right is dropped at once: the send-once notification comes back.
        let m = try host.receive(on: reply, timeout: 5_000_000_000)
        #expect(m.id == MachNotify.sendOnce)
        #expect(service.connectionCount == 0 && service.held == 0)
    }
}
