import Foundation
import Testing
@testable import YcodeDarwinKernel
@testable import YcodeHostServices

/// The minimal host SCDynamicStore (scdynamicstore-host.md §4), driven over
/// Mach by a second host task acting as the configd client.
@Suite(.serialized) struct SCDynamicStoreHostServiceTests {
    static let ndr: [UInt8] = [0, 0, 0, 1, 0, 0, 0, 0]

    func le(_ v: Int32) -> [UInt8] { withUnsafeBytes(of: v.littleEndian) { Array($0) } }
    func i32(_ b: [UInt8], _ at: Int) -> Int32 { b.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: at, as: Int32.self) } }

    struct Env {
        let system: DarwinSystem
        let service: SCDynamicStoreHostService
        let client: MachHostTask
        let server: UInt32
        let replyPort: UInt32
    }

    func env() throws -> Env {
        let system = DarwinSystem()
        let host = system.hostTask
        let service = try SCDynamicStoreHostService(host: host, log: { _ in })
        service.start()
        let client = system.lock.withLock { MachHostTask(lock: system.lock, system: system.mach, log: { _ in }) }
        let server = try host.give(service.servicePort, disposition: MachMsgType.copySend, to: client.ipc)
        return Env(system: system, service: service, client: client, server: server, replyPort: try client.makePort())
    }

    func call(_ e: Env, to port: UInt32, id: Int32, descriptors: [MachHostDescriptor] = [], body: [UInt8])
        throws -> MachHostReceivedMessage {
        try e.client.send(MachHostOutgoingMessage(remotePort: port, localPort: e.replyPort,
                                                  localDisposition: MachMsgType.makeSendOnce, id: id,
                                                  descriptors: descriptors, body: body))
        return try e.client.receive(on: e.replyPort, timeout: 5_000_000_000)
    }

    @Test func openSessionNotifyAndLookUp() throws {
        let e = try env()
        defer { e.service.stop() }
        let name = Array("SimulatorSupport(host)".utf8), options = Array("<dict/>".utf8)
        // configopen on the service port: a session port and status 0.
        let open = try call(e, to: e.server, id: 20000, descriptors: [.ool(data: name), .ool(data: options)],
                            body: Self.ndr + le(Int32(name.count)) + le(Int32(options.count)))
        #expect(open.id == 20100 && open.size == 52)
        guard case let .port(session, type)? = open.descriptors.first else {
            Issue.record("no session port")
            return
        }
        #expect(type == 17)  // PORT_SEND
        #expect(Array(open.body.prefix(8)) == Self.ndr && i32(open.body, 8) == 0)
        // notifyset: RetCode 0, status 0.
        let set = try call(e, to: session, id: 20025, descriptors: [.ool(data: [1]), .ool(data: [2])],
                           body: Self.ndr + le(1) + le(1))
        #expect(set.id == 20125 && i32(set.body, 8) == 0 && i32(set.body, 12) == 0)
        // notifyviaport with a send right: accepted.
        let notify = try e.client.makePort()
        let via = try call(e, to: session, id: 20021, descriptors: [.port(name: notify, disposition: MachMsgType.makeSend)],
                           body: Self.ndr + le(0))
        #expect(via.id == 20121 && i32(via.body, 12) == 0)
        // configget_m: no key (1004), an empty out-of-line array.
        let get = try call(e, to: session, id: 20016, descriptors: [.ool(data: [1]), .ool(data: [2])],
                           body: Self.ndr + le(1) + le(1))
        #expect(get.id == 20116 && get.descriptors.count == 1 && i32(get.body, 8) == 0 && i32(get.body, 12) == 1004)
        // notifychanges: OK with a (binary plist) empty array.
        let changes = try call(e, to: session, id: 20020, body: Self.ndr)
        #expect(changes.id == 20120 && i32(changes.body, 12) == 0)
        if case let .ool(data, _, _)? = changes.descriptors.first {
            #expect(Array(data.prefix(6)) == Array("bplist".utf8))
        } else {
            Issue.record("no change list")
        }
        // A session routine on the service port: no session (2001).
        let wrong = try call(e, to: e.server, id: 20025, descriptors: [.ool(data: [1]), .ool(data: [2])],
                             body: Self.ndr + le(1) + le(1))
        #expect(i32(wrong.body, 12) == 2001)
        // An unknown id: MIG_BAD_ID.
        let bad = try call(e, to: session, id: 20099, body: Self.ndr)
        #expect(bad.id == 20199 && i32(bad.body, 8) == -303)
    }
}
