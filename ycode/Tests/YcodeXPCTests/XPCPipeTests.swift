import Foundation
import Testing
@testable import YcodeXPC

@Suite struct XPCPipeTests {
    // MARK: Replies accepted by real clients (§7)

    @Test func errorReplyIs64Bytes() throws {
        let m = XPCPipeReply.error(XPCBootstrapError.unknownService)
        #expect(m.id == 0x2000_0000)
        #expect(m.msghID == 0x2000_0000)
        #expect(!m.isComplex)
        #expect(m.messageSize == 64)
        #expect(m.body == ascii("?cpx") + le32(5) + le32(0xF000) + le32(24) + le32(1)
            + ascii("error") + [0, 0, 0] + le32(0x3000) + le64(1102))
        #expect(try m.decodeDictionary() == ["error": .int64(1102)])
    }

    @Test func sendRightReplyIs72Bytes() throws {
        let m = XPCPipeReply.sendRight(0x1503)
        #expect(m.id == XPCPipe.replyID)
        #expect(m.isComplex)
        #expect(m.descriptors == [.port(name: 0x1503, disposition: XPCDisposition.makeSend)])
        #expect(m.messageSize == 72)
        #expect(m.body == ascii("?cpx") + le32(5) + le32(0xF000) + le32(16) + le32(1)
            + ascii("port") + [0, 0, 0, 0] + le32(0xD000))
    }

    @Test func receiveRightReplyIs72Bytes() throws {
        let m = XPCPipeReply.receiveRight(0x1607)
        #expect(m.descriptors == [.port(name: 0x1607, disposition: XPCDisposition.moveReceive)])
        #expect(m.messageSize == 72)
        #expect(Array(m.body.suffix(4)) == le32(0x15000))
        // The client's view: the descriptor arrives as a receive right (type 16).
        let d = try XPCPipeMessage(id: m.id, descriptors: [.port(name: 0x2303, disposition: 16)], body: m.body)
            .decodeDictionary()
        #expect(d["port"] == .receiveRight(XPCPort(name: 0x2303, disposition: 16)))
    }

    @Test func emptyReply() throws {
        let m = XPCPipeReply.empty()
        #expect(m.body == ascii("?cpx") + le32(5) + le32(0xF000) + le32(4) + le32(0))
        #expect(!m.isComplex)
        #expect(m.messageSize == 44)
        #expect(try m.decodeDictionary().isEmpty)
    }

    @Test func customKeysAndDispositions() throws {
        let m = XPCPipeReply.sendRight(7, disposition: XPCDisposition.copySend, key: "parent")
        #expect(try m.decodeDictionary().keys == ["parent"])
        #expect(m.descriptors == [.port(name: 7, disposition: 19)])
        let lookUpMiss = try XPCPipeReply.dictionary([
            "rec_execcnt": .uint64(1), "req_pid": .uint64(100), "error": .int64(XPCBootstrapError.unknownService),
        ])
        #expect(!lookUpMiss.isComplex)
        // A NUL in a caller's key cannot be encoded; the builder falls back to an error reply.
        #expect(try XPCPipeReply.sendRight(1, key: "a\0").decodeDictionary() == ["error": .int64(22)])
    }

    // MARK: Requests (§2.1, §4)

    @Test func routineAndOneWayIDs() throws {
        let body = try XPCWire.encodePayload(["name": "x"])
        let r = try XPCPipeRequest(msghID: 0x4000_0325, body: body, descriptors: [], hasReplyPort: true)
        #expect(r.routine == 805)
        #expect(r.knownRoutine == .listenerCheckIn)
        #expect(!r.isOneWay)
        let general = try XPCPipeRequest(id: 0x4000_0000, body: body, descriptors: [], hasReplyPort: true)
        #expect(general.routine == 0)
        #expect(general.knownRoutine == nil)
        let oneWay = try XPCPipeRequest(id: 0x1000_0000, body: body, descriptors: [], hasReplyPort: false)
        #expect(oneWay.isOneWay)
        #expect(oneWay.routine == 0)
        #expect(oneWay.knownRoutine == nil)
        #expect(throws: XPCPipeRequest.Failure.notPipeRequest(708)) {
            try XPCPipeRequest(id: 708, body: [], descriptors: [], hasReplyPort: true)
        }
        #expect(XPCPipe.isRequest(id: 0x4000_00CF))
        #expect(!XPCPipe.isRequest(id: 708))
        #expect(!XPCPipe.isRequest(id: XPCPipe.replyID))
        #expect(try XPCPipeMessage.oneWay([:]).id == 0x1000_0000)
    }

    @Test func rootMustBeADictionary() throws {
        let body = try XPCWire.encodePayload(["not", "a dictionary"])
        #expect(throws: XPCWireError.rootNotDictionary) {
            try XPCPipeRequest(id: 0x4000_00CF, body: body, descriptors: [], hasReplyPort: true)
        }
    }

    @Test func registerRequestCarriesItsPort() throws {
        // 204: handle 0, flags 0, name, type 7, port (0xD000) with one descriptor.
        let sent = try XPCPipeMessage.request(routine: 204, [
            "handle": .uint64(0), "flags": .uint64(0), "name": "com.example.svc", "type": .uint64(7),
            "port": .send(0x40, disposition: XPCDisposition.copySend),
        ])
        #expect(sent.id == 0x4000_00CC)
        #expect(sent.isComplex)
        // As received: the receiver's name, received type 17.
        let r = try XPCPipeRequest(id: sent.id, body: sent.body, descriptors: [.port(name: 0x1103, disposition: 17)],
                                   hasReplyPort: true)
        #expect(r.knownRoutine == .register)
        #expect(r.port == XPCPort(name: 0x1103, disposition: 17))
        #expect(r.ports == [XPCPort(name: 0x1103, disposition: 17)])
        #expect(r.description == #"pipe 204 (register) {handle: 0, flags: 0, name: "com.example.svc", type: 7, "#
            + #"port: send(0x1103/17)}"#)
    }

    @Test func serviceLookUpAndPrintRequests() throws {
        let lookUp = try XPCPipeMessage.request(routine: 804, [
            "handle": .uint64(0), "flags": .uint64(8), "name": "com.apple.diagnosticd", "type": .uint64(7),
            "lookup-handle": .uint64(0),
        ])
        let r = try XPCPipeRequest(id: lookUp.id, body: lookUp.body, descriptors: [], hasReplyPort: true)
        #expect(r.knownRoutine == .serviceLookUp)
        #expect(!r.knownRoutine!.isLegacy)
        #expect(r.flags == 8)
        #expect(r.lookupHandle == 0)
        #expect(r.targetPID == nil)
        #expect(r.description.hasPrefix("pipe 804 (xpc-look-up) {"))

        let print = try XPCPipeMessage.request(routine: 828, [
            "handle": .uint64(0),
            "shmem": .sharedMemory(size: 1 << 20, port: XPCPort(name: 0x88, disposition: XPCDisposition.makeSend)),
            "type": .uint64(XPCBootstrapDomain.system),
        ])
        #expect(print.descriptors == [.port(name: 0x88, disposition: 20)])
        let pr = try XPCPipeRequest(id: print.id, body: print.body, descriptors: [.port(name: 0x99, disposition: 17)],
                                    hasReplyPort: true)
        #expect(pr.dictionary["shmem"] == .sharedMemory(size: 1 << 20, port: XPCPort(name: 0x99, disposition: 17)))
        #expect(pr.type == 1)
    }

    @Test func requestDecodesPayloadOutOfLine() throws {
        let payload = try XPCWire.encodePayload(.dictionary(lookUpDictionary))
        let r = try XPCPipeRequest(id: 0x4000_00CF, body: [],
                                   descriptors: [.ool(bytes: payload + [UInt8](repeating: 0, count: 16384 - payload.count))],
                                   hasReplyPort: true)
        #expect(r.name == "com.apple.cfprefsd.daemon")
    }

    @Test func routineTable() {
        #expect(XPCBootstrapRoutine.allCases.map(\.rawValue) == [203, 204, 205, 206, 207, 708, 802, 803, 804, 805, 828])
        #expect(XPCBootstrapRoutine.checkIn.isLegacy)
        #expect(XPCBootstrap.launchdSimServiceRequestID == 708)
        #expect(XPCBootstrap.launchdSimServiceReplyID == 808)
    }
}
