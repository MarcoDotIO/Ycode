import Foundation
import Testing
import YcodeDarwinABI
@testable import YcodeDarwinKernel

/// `YCODE_LOOKUP_HOLD` (`LookupHold.swift`, boot-profile.md §18): a failure
/// reply to a look-up of a listed name is delivered at the release time.
extension KernelSwitchSuites {
@Suite(.serialized) struct LookupHoldTests {
    let rcv = MachMsgOption.rcvMsg | MachMsgOption.rcvTimeout

    /// A pipe request of routine `id` naming `name`, with a send-once reply right.
    func request(_ server: UInt32, reply: UInt32, id: Int32, name: String) -> [UInt8] {
        var body = Array("name".utf8) + [0, 0, 0, 0] + Array(name.utf8) + [0]
        while body.count % 4 != 0 { body.append(0) }
        return TestMessage(remote: server, remoteDisposition: MachMsgType.copySend, local: reply,
                           localDisposition: MachMsgType.makeSendOnce, id: id, inline: body).bytes
    }

    /// Serves one request on `server`: replies `{error}` (or a body without it).
    func answer(_ env: IPCEnv, _ server: UInt32, failure: Bool) {
        let (code, raw) = env.receive(server)
        #expect(code == 0)
        let r = Received(raw)
        let body = failure ? Array("error".utf8) + [0, 0, 0] : Array("rec_".utf8)
        let msg = TestMessage(remote: r.remote, remoteDisposition: MachMsgType.moveSendOnce, id: 0x2000_0000, inline: body)
        #expect(env.send(msg.bytes) == 0)
    }

    func withHold(_ names: [String], seconds: Double, _ body: () throws -> Void) rethrows {
        let (savedNames, savedRelease) = (LookupHold.names, LookupHold.releaseAfter)
        LookupHold.names = names
        LookupHold.releaseAfter = UInt64(seconds * 1_000_000_000)
        defer { (LookupHold.names, LookupHold.releaseAfter) = (savedNames, savedRelease) }
        try body()
    }

    @Test func failedLookUpOfAListedNameIsHeldUntilTheReleaseTime() throws {
        try withHold(["com.example.missing"], seconds: 0.4) {
            let env = try IPCEnv()
            let server = env.allocate()
            #expect(env.insertRight(server, server, MachMsgType.makeSend) == 0)
            let reply = env.allocate()
            #expect(env.send(request(server, reply: reply, id: 0x4000_0324, name: "com.example.missing")) == 0)
            answer(env, server, failure: true)
            #expect(env.receive(reply).0 == MachMsgReturn.rcvTimedOut)  // held
            let (code, raw) = env.receive(reply, options: rcv, timeout: 3000)
            #expect(code == 0 && Received(raw).id == 0x2000_0000)
            // After the release time the next failure passes at once.
            #expect(env.send(request(server, reply: reply, id: 0x4000_0324, name: "com.example.missing")) == 0)
            answer(env, server, failure: true)
            #expect(env.receive(reply).0 == 0)
        }
    }

    @Test func otherNamesAndGrantedLookUpsPassAtOnce() throws {
        try withHold(["com.example.missing"], seconds: 30) {
            let env = try IPCEnv()
            let server = env.allocate()
            #expect(env.insertRight(server, server, MachMsgType.makeSend) == 0)
            let reply = env.allocate()
            // Another name: its failure is not held.
            #expect(env.send(request(server, reply: reply, id: 0x4000_0324, name: "com.example.other")) == 0)
            answer(env, server, failure: true)
            #expect(env.receive(reply).0 == 0)
            // A listed name that is answered without an error: not held.
            #expect(env.send(request(server, reply: reply, id: 0x4000_00CF, name: "com.example.missing")) == 0)
            answer(env, server, failure: false)
            #expect(env.receive(reply).0 == 0)
            // The mark is one-shot: a later plain message to the reply port passes.
            #expect(env.ipc.messageQueued(on: reply) == false)
        }
    }

    @Test func offByDefault() {
        #expect(LookupHold.parseNames(nil).isEmpty)
        #expect(LookupHold.parseNames(" a , b,,") == ["a", "b"])
    }
}
}
