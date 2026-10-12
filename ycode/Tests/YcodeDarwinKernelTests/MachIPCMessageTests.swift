import Foundation
import Testing
import YcodeDarwinABI
@testable import YcodeDarwinKernel

/// `mach-ipc.md` §2: messages, dispositions, descriptors, trailers, return codes.
@Suite struct MachIPCMessageTests {
    let S = MachPortType.send, R = MachPortType.receive, SO = MachPortType.sendOnce, DN = MachPortType.deadName
    let rcv = MachMsgOption.rcvMsg | MachMsgOption.rcvTimeout

    /// A server port with a send right, and a reply port.
    func ports(_ env: IPCEnv) -> (server: UInt32, reply: UInt32) {
        let server = env.allocate()
        #expect(env.insertRight(server, server, MachMsgType.makeSend) == 0)
        return (server, env.allocate())
    }

    @Test func simpleSendAndReceive() throws {
        let env = try IPCEnv()
        let (server, reply) = ports(env)
        let msg = TestMessage(remote: server, remoteDisposition: MachMsgType.copySend, local: reply,
                              localDisposition: MachMsgType.makeSendOnce, voucher: 0x5555, id: 1234,
                              inline: [1, 2, 3, 4, 5, 6, 7, 8])
        #expect(env.send(msg.bytes) == 0)
        #expect(env.ipc.portCounters(server)?.srights == 2)  // the entry and the message
        #expect(env.ipc.portCounters(reply)?.sorights == 1)
        #expect(env.ipc.messageQueued(on: server))
        let (code, raw) = env.receive(server)
        #expect(code == 0)
        let r = Received(raw)
        #expect(r.bits == 0x1112)  // remote = send-once (18), local = send (17)
        #expect(r.size == 32)
        #expect(r.local == server)
        #expect(r.voucher == 0x5555)  // voucher disposition 0: the field round-trips
        #expect(r.id == 1234)
        #expect(Array(raw[24..<32]) == [1, 2, 3, 4, 5, 6, 7, 8])
        #expect(r.trailer(0) == 0 && r.trailer(4) == 8)  // NULL trailer
        #expect(env.type(r.remote) == (0, SO))
        #expect(env.ipc.portCounters(server)?.srights == 1)
        #expect(env.ipc.portCounters(server)?.seqno == 1)
        #expect(!env.ipc.messageQueued(on: server))

        // Reply through the send-once right.
        let answer = TestMessage(remote: r.remote, remoteDisposition: MachMsgType.moveSendOnce, id: 1334)
        #expect(env.send(answer.bytes) == 0)
        #expect(env.type(r.remote).0 == MachKern.invalidName)
        let (code2, raw2) = env.receive(reply)
        #expect(code2 == 0)
        let r2 = Received(raw2)
        #expect(r2.bits == 0x1200 && r2.remote == 0 && r2.local == reply && r2.id == 1334)
        #expect(env.ipc.portCounters(reply)?.sorights == 0)
        // Nothing queued: timeout 0 returns at once.
        #expect(env.receive(reply).0 == MachMsgReturn.rcvTimedOut)
    }

    @Test func trailers() throws {
        let env = try IPCEnv()
        let (server, _) = ports(env)
        #expect(env.kr(-41, [env.task, UInt64(server), 0xC0FFEE, 0]) == 0)  // context 0xC0FFEE
        for (elements, size) in [(0, 8), (1, 12), (2, 20), (3, 52), (4, 60), (5, 68), (7, 68), (8, 68), (15, 68)] {
            #expect(env.send(TestMessage(remote: server, remoteDisposition: MachMsgType.copySend).bytes) == 0)
            let (code, raw) = env.receive(server, options: rcv | UInt64(elements) << 24)
            #expect(code == 0)
            let r = Received(raw)
            #expect(r.trailer(4) == UInt32(size))
            if size >= 12 { #expect(r.trailer(8) == env.ipc.portCounters(server)!.seqno - 1) }
            if size >= 20 { #expect(r.trailer(12) == 501 && r.trailer(16) == 20) }
            if size >= 52 { #expect(r.trailer(20 + 4 * 5) == 100) }  // audit pid
            if size >= 60 { #expect(r.u64(Int(r.size) + 52) == 0xC0FFEE) }
            // Nothing past the requested trailer is written.
            #expect(raw[Int(r.size) + size] == 0xEE)
        }
    }

    @Test func makeSendDestinationAndNoSenders() throws {
        let env = try IPCEnv()
        let p = env.allocate(), n = env.allocate()
        #expect(env.requestNotification(p, MachNotify.noSenders, sync: 1, notify: n) == (0, 0))
        #expect(env.send(TestMessage(remote: p, remoteDisposition: MachMsgType.makeSend).bytes) == 0)
        #expect(env.ipc.portCounters(p)?.mscount == 1 && env.ipc.portCounters(p)?.srights == 1)
        #expect(env.receive(n).0 == MachMsgReturn.rcvTimedOut)
        let (code, raw) = env.receive(p)
        #expect(code == 0 && Received(raw).bits == 0x1100)
        // The destination right was consumed: srights 0 → no-senders with mscount 1.
        let (c2, raw2) = env.receive(n, options: rcv | 2 << 24)
        #expect(c2 == 0)
        let note = Received(raw2)
        #expect(note.id == MachNotify.noSenders && note.size == 36 && note.bits == 0x1200)
        #expect(note.local == n && note.remote == 0)
        #expect(Array(raw2[24..<32]) == machNDRRecord && note.u32(32) == 1)
        #expect(note.trailer(12) == 0 && note.trailer(16) == 1)  // kernel sender {0, 1}
    }

    @Test func headerErrorsLeaveRightsUntouched() throws {
        let env = try IPCEnv()
        let (server, reply) = ports(env)
        func send(_ m: TestMessage) -> UInt32 { env.send(m.bytes) }
        let ok = TestMessage(remote: server, remoteDisposition: MachMsgType.moveSend)
        var m = ok
        m.local = reply
        #expect(send(m) == MachMsgReturn.sendInvalidHeader)  // reply name with disposition 0
        m = ok; m.local = reply; m.localDisposition = 22
        #expect(send(m) == MachMsgReturn.sendInvalidHeader)
        m = ok; m.remoteDisposition = MachMsgType.moveReceive
        #expect(send(m) == MachMsgReturn.sendInvalidHeader)
        m = ok; m.remote = 0
        #expect(send(m) == MachMsgReturn.sendInvalidDest)
        m = ok; m.remote = 0x44403
        #expect(send(m) == MachMsgReturn.sendInvalidDest)
        m = ok; m.voucherDisposition = MachMsgType.makeSendOnce
        #expect(send(m) == MachMsgReturn.sendInvalidVoucher)
        m = ok; m.voucher = MachPortName.dead; m.voucherDisposition = MachMsgType.copySend
        #expect(send(m) == MachMsgReturn.sendInvalidVoucher)
        m = ok; m.voucher = server; m.voucherDisposition = MachMsgType.copySend
        #expect(send(m) == MachMsgReturn.sendInvalidVoucher)  // not a voucher object
        m = ok; m.local = 0x44403; m.localDisposition = MachMsgType.makeSendOnce
        #expect(send(m) == MachMsgReturn.sendInvalidReply)
        m = ok; m.local = server; m.localDisposition = MachMsgType.moveSendOnce
        #expect(send(m) == MachMsgReturn.sendInvalidDest)  // dest == reply with MOVE_SEND_ONCE
        m = ok; m.local = server; m.localDisposition = MachMsgType.moveSend
        #expect(send(m) == MachMsgReturn.sendInvalidDest)  // MOVE_SEND twice needs 2 urefs
        m = ok; m.remoteDisposition = MachMsgType.copySend; m.remote = reply
        #expect(send(m) == MachMsgReturn.sendInvalidDest)  // no send right
        // The bootstrap port answers MACH_SEND_INVALID_DEST until launchd owns it.
        m = ok; m.remote = 0x503; m.remoteDisposition = MachMsgType.copySend
        #expect(send(m) == MachMsgReturn.sendInvalidDest)
        // Sizes.
        #expect(env.kr(-31, [IPCEnv.sendBuffer, 1, 20, 0, 0, 0, 0]) == MachMsgReturn.sendMsgTooSmall)
        #expect(env.kr(-31, [IPCEnv.sendBuffer, 1, 26, 0, 0, 0, 0]) == MachMsgReturn.sendMsgTooSmall)
        #expect(env.kr(-31, [IPCEnv.sendBuffer, 1, 0x400_0000, 0, 0, 0, 0]) == MachMsgReturn.sendTooLarge)
        #expect(env.kr(-31, [0x10, 1, 24, 0, 0, 0, 0]) == MachMsgReturn.sendInvalidData)
        m = ok; m.complex = true
        var bytes = m.bytes
        env.put(bytes, at: IPCEnv.sendBuffer)
        #expect(env.kr(-31, [IPCEnv.sendBuffer, 1, 24, 0, 0, 0, 0]) == MachMsgReturn.sendMsgTooSmall)
        bytes.replaceSubrange(24..<28, with: le32(1))  // 1 descriptor in 0 bytes
        #expect(env.send(bytes) == MachMsgReturn.sendMsgTooSmall)
        m = ok; m.descriptors = [[0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 9, 0, 0, 0, 0]]
        #expect(send(m) == MachMsgReturn.sendInvalidType)
        m = ok; m.descriptors = [TestMessage.ool(IPCEnv.scratch, size: 4, copy: 2)]
        #expect(send(m) == MachMsgReturn.sendInvalidType)
        m = ok; m.descriptors = [TestMessage.port(reply, 22)]
        #expect(send(m) == MachMsgReturn.sendInvalidType)
        m = ok; m.descriptors = [TestMessage.guarded(reply, context: 0, flags: 1, disposition: MachMsgType.moveSend)]
        #expect(send(m) == MachMsgReturn.sendInvalidType)
        m = ok; m.descriptors = [TestMessage.guarded(reply, context: 5, flags: 2)]
        #expect(send(m) == MachMsgReturn.sendInvalidType)
        // Nothing changed.
        #expect(env.type(server) == (0, S | R) && env.urefs(server) == 1)
        #expect(env.ipc.portCounters(server)?.srights == 1)
        #expect(env.ipc.portCounters(reply)?.sorights == 0)
        #expect(!env.ipc.messageQueued(on: server))
        #expect(send(ok) == 0)
        #expect(env.type(server) == (0, R))  // the last send uref moved
    }

    @Test func destinationAndReplyInOneEntry() throws {
        let env = try IPCEnv()
        let p = env.allocate()
        #expect(env.insertRight(p, p, MachMsgType.makeSend) == 0)
        #expect(env.modRefs(p, MachPortRight.send, 1) == 0)
        // MOVE_SEND twice with 2 urefs, to the port itself.
        let m = TestMessage(remote: p, remoteDisposition: MachMsgType.moveSend, local: p,
                            localDisposition: MachMsgType.moveSend)
        #expect(env.send(m.bytes) == 0)
        #expect(env.type(p) == (0, R))
        let (code, raw) = env.receive(p)
        #expect(code == 0)
        let r = Received(raw)
        #expect(r.bits == 0x1111 && r.remote == p && r.local == p)
        #expect(env.type(p) == (0, S | R) && env.urefs(p) == 1)
        #expect(env.ipc.portCounters(p)?.srights == 1)
    }

    @Test func portDescriptors() throws {
        let env = try IPCEnv()
        let (server, _) = ports(env)
        let x = env.allocate(), y = env.allocate()
        let m = TestMessage(remote: server, remoteDisposition: MachMsgType.copySend,
                            descriptors: [TestMessage.port(x, MachMsgType.makeSend),
                                          TestMessage.port(y, MachMsgType.moveReceive),
                                          TestMessage.port(0, MachMsgType.copySend),
                                          TestMessage.port(MachPortName.dead, MachMsgType.moveSendOnce),
                                          TestMessage.port(x, MachMsgType.makeSendOnce)],
                            inline: [0xAB, 0xCD, 0, 0])
        #expect(env.send(m.bytes) == 0)
        #expect(env.type(y).0 == MachKern.invalidName)  // the receive right left the space
        let (code, raw) = env.receive(server)
        #expect(code == 0)
        let r = Received(raw)
        #expect(r.bits & MachMsgBits.complex != 0)
        #expect(r.size == 24 + 4 + 5 * 12 + 4)
        #expect(r.u32(24) == 5)
        func desc(_ k: Int) -> (name: UInt32, disposition: UInt8, type: UInt8) {
            let o = 28 + 12 * k
            return (r.u32(o), raw[o + 10], raw[o + 11])
        }
        // The send right merges into x's entry.
        #expect(desc(0) == (x, 17, 0))
        #expect(env.type(x) == (0, S | R))
        // y's receive right comes back under a new name (y's slot, next generation).
        #expect(desc(1).disposition == 16)
        let y2 = desc(1).name
        #expect(y2 != y && y2 >> 8 == y >> 8 && env.type(y2) == (0, R))
        #expect(desc(2) == (0, 17, 0))
        #expect(desc(3) == (MachPortName.dead, 18, 0))
        #expect(desc(4).disposition == 18 && env.type(desc(4).name) == (0, SO))
        #expect(Array(raw[(Int(r.size) - 4)..<Int(r.size)]) == [0xAB, 0xCD, 0, 0])
    }

    @Test func oolMemory() throws {
        let env = try IPCEnv()
        let (server, _) = ports(env)
        let region = try env.space.mapAnonymous(at: nil, size: 0x8000, protection: .readWrite, hint: nil)
        let pattern = (0..<300).map { UInt8(truncatingIfNeeded: $0 * 7) }
        env.put(pattern, at: region + 0x10)
        let m = TestMessage(remote: server, remoteDisposition: MachMsgType.copySend,
                            descriptors: [TestMessage.ool(region + 0x10, size: 300, copy: 0),
                                          TestMessage.ool(region + 0x10, size: 300, deallocate: true, copy: 1),
                                          TestMessage.ool(0, size: 0)])
        #expect(env.send(m.bytes) == 0)
        // deallocate = 1 removed the sender's pages.
        #expect((try? env.space.read(va: region + 0x10, count: 1)) == nil)
        let (code, raw) = env.receive(server)
        #expect(code == 0)
        let r = Received(raw)
        for k in 0..<2 {
            let o = 28 + 16 * k
            let address = r.u64(o)
            #expect(address != 0 && address != region + 0x10)
            #expect(address % DarwinKernel.pageSize == 0)
            #expect(raw[o + 8] == UInt8(k))  // deallocate = (copy == VIRTUAL_COPY)
            #expect(raw[o + 9] == UInt8(k))
            #expect(raw[o + 11] == MachMsgDescriptor.ool)
            #expect(r.u32(o + 12) == 300)
            #expect(env.read(address, 300) == pattern)
        }
        #expect(r.u64(28 + 32) == 0 && r.u32(28 + 32 + 12) == 0)
        // Later writes by the sender are not seen: the data was captured at send.
        let region2 = try env.space.mapAnonymous(at: nil, size: 0x4000, protection: .readWrite, hint: nil)
        env.put([1, 2, 3, 4], at: region2)
        #expect(env.send(TestMessage(remote: server, remoteDisposition: MachMsgType.copySend,
                                     descriptors: [TestMessage.ool(region2, size: 4)]).bytes) == 0)
        env.put([9, 9, 9, 9], at: region2)
        let (_, raw2) = env.receive(server)
        #expect(env.read(Received(raw2).u64(28), 4) == [1, 2, 3, 4])
        // An unreadable range destroys the header rights.
        let (server2, reply2) = ports(env)
        let bad = TestMessage(remote: server2, remoteDisposition: MachMsgType.moveSend, local: reply2,
                              localDisposition: MachMsgType.makeSendOnce,
                              descriptors: [TestMessage.ool(0x10, size: 8)])
        #expect(env.send(bad.bytes) == MachMsgReturn.sendInvalidMemory)
        #expect(env.type(server2) == (0, R))  // the moved send right is gone
        #expect(env.ipc.portCounters(server2)?.srights == 0)
        // The destroyed MAKE_SEND_ONCE reply right produced a send-once notification.
        let (c3, raw3) = env.receive(reply2)
        #expect(c3 == 0 && Received(raw3).id == MachNotify.sendOnce && Received(raw3).size == 24)
    }

    @Test func oolPorts() throws {
        let env = try IPCEnv()
        let (server, _) = ports(env)
        let x = env.allocate()
        let array = IPCEnv.scratch + 0x2000
        env.put(le32(x) + le32(0) + le32(MachPortName.dead) + le32(x), at: array)
        let m = TestMessage(remote: server, remoteDisposition: MachMsgType.copySend,
                            descriptors: [TestMessage.oolPorts(array, count: 4, disposition: MachMsgType.makeSend)])
        #expect(env.send(m.bytes) == 0)
        #expect(env.ipc.portCounters(x)?.mscount == 2)
        let (code, raw) = env.receive(server)
        #expect(code == 0)
        let r = Received(raw)
        let address = r.u64(28)
        #expect(address != 0 && address != array)
        #expect(raw[28 + 8] == 1 && raw[28 + 9] == 1 && raw[28 + 10] == 17 && raw[28 + 11] == 2)
        #expect(r.u32(28 + 12) == 4)
        #expect(env.read(address, 16) == le32(x) + le32(0) + le32(MachPortName.dead) + le32(x))
        #expect(env.type(x) == (0, S | R) && env.urefs(x) == 2)
        #expect(env.ipc.portCounters(x)?.srights == 1)
        // A bad name in the array releases the rights already copied in.
        env.put(le32(x) + le32(0x55503), at: array)
        let bad = TestMessage(remote: server, remoteDisposition: MachMsgType.copySend,
                              descriptors: [TestMessage.oolPorts(array, count: 2, disposition: MachMsgType.copySend)])
        #expect(env.send(bad.bytes) == MachMsgReturn.sendInvalidRight)
        #expect(env.ipc.portCounters(x)?.srights == 1)
        #expect(env.ipc.portCounters(server)?.srights == 1)
        let unreadable = TestMessage(remote: server, remoteDisposition: MachMsgType.copySend,
                                     descriptors: [TestMessage.oolPorts(0x10, count: 2, disposition: MachMsgType.copySend)])
        #expect(env.send(unreadable.bytes) == MachMsgReturn.sendInvalidMemory)
    }

    @Test func guardedPortDescriptors() throws {
        let env = try IPCEnv()
        let (server, _) = ports(env)
        let (_, g) = env.construct(flags: MachPortConstruct.contextAsGuard, context: 0x1234)
        // Wrong guard: INVALID_RIGHT, header rights destroyed.
        var m = TestMessage(remote: server, remoteDisposition: MachMsgType.copySend,
                            descriptors: [TestMessage.guarded(g, context: 0x9999, flags: 1)])
        #expect(env.send(m.bytes) == MachMsgReturn.sendInvalidRight)
        #expect(env.type(g) == (0, R))
        m.descriptors = [TestMessage.guarded(g, context: 0x1234, flags: 1)]
        #expect(env.send(m.bytes) == 0)
        #expect(env.type(g).0 == MachKern.invalidName)
        let (code, raw) = env.receive(server, options: rcv | MachMsgOption.rcvGuardedDesc)
        #expect(code == 0)
        let r = Received(raw)
        let name = r.u32(28 + 12)
        #expect(raw[28 + 10] == 16 && raw[28 + 11] == 4)
        #expect(r.u64(28) == IPCEnv.receiveBuffer)  // guarded with the receive buffer's address
        #expect(env.type(name) == (0, R))
        // Immovable now: it cannot be moved again.
        let move = TestMessage(remote: server, remoteDisposition: MachMsgType.copySend,
                               descriptors: [TestMessage.port(name, MachMsgType.moveReceive)])
        #expect(env.send(move.bytes) == MachMsgReturn.sendInvalidRight)
        // Without MACH_RCV_GUARDED_DESC the right is destroyed.
        let plain = env.allocate()
        m.descriptors = [TestMessage.guarded(plain, context: 0, flags: 2)]  // UNGUARDED_ON_SEND
        #expect(env.send(m.bytes) == 0)
        let (code2, raw2) = env.receive(server)
        #expect(code2 == 0)
        #expect(Received(raw2).u32(28 + 12) == 0 && Received(raw2).u64(28) == 0)
    }

    @Test func circularMessagesAreDestroyed() throws {
        let env = try IPCEnv()
        let (server, _) = ports(env)
        let m = TestMessage(remote: server, remoteDisposition: MachMsgType.copySend,
                            descriptors: [TestMessage.port(server, MachMsgType.moveReceive)])
        #expect(env.send(m.bytes) == 0)
        // The receive right went into its own queue: the message and port are destroyed.
        #expect(env.type(server) == (0, DN))
        // Through a chain: a's receive right is queued on b; sending b's receive right to a.
        let a = env.allocate(), b = env.allocate()
        #expect(env.send(TestMessage(remote: b, remoteDisposition: MachMsgType.makeSend,
                                     descriptors: [TestMessage.port(a, MachMsgType.moveReceive)]).bytes) == 0)
        let a2Holder = b
        #expect(env.ipc.messageQueued(on: a2Holder))
        // a's receive right is in transit; we still need a send right to a: none left (moved). Use b's chain:
        let c = env.allocate()
        #expect(env.send(TestMessage(remote: c, remoteDisposition: MachMsgType.makeSend,
                                     descriptors: [TestMessage.port(b, MachMsgType.moveReceive)]).bytes) == 0)
        #expect(env.send(TestMessage(remote: c, remoteDisposition: MachMsgType.makeSend,
                                     descriptors: [TestMessage.port(c, MachMsgType.moveReceive)]).bytes) == 0)
        #expect(env.type(c).0 == MachKern.invalidName)
    }

    @Test func tooLargeWithRcvLarge() throws {
        let env = try IPCEnv()
        let (server, reply) = ports(env)
        let m = TestMessage(remote: server, remoteDisposition: MachMsgType.copySend, local: reply,
                            localDisposition: MachMsgType.makeSendOnce, id: 77,
                            inline: [UInt8](repeating: 0x42, count: 100))
        #expect(env.send(m.bytes) == 0)
        let large = rcv | MachMsgOption.rcvLarge | MachMsgOption.rcvLargeIdentity
        let (code, raw) = env.receive(server, size: 64, options: large)
        #expect(code == MachMsgReturn.rcvTooLarge)
        #expect(Received(raw).size == 124 && Received(raw).local == server)
        #expect(raw[0] == 0xEE)  // nothing else written
        #expect(env.ipc.messageQueued(on: server))
        #expect(env.ipc.portCounters(server)?.seqno == 0)
        let (code2, raw2) = env.receive(server, size: 124 + 8, options: large)
        #expect(code2 == 0 && Received(raw2).id == 77)
    }

    @Test func tooLargeWithoutRcvLargeDestroysTheMessage() throws {
        let env = try IPCEnv()
        let (server, reply) = ports(env)
        let x = env.allocate()
        let m = TestMessage(remote: server, remoteDisposition: MachMsgType.copySend, local: reply,
                            localDisposition: MachMsgType.makeSendOnce, id: 78,
                            descriptors: [TestMessage.port(x, MachMsgType.makeSend)],
                            inline: [UInt8](repeating: 0x42, count: 100))
        #expect(env.send(m.bytes) == 0)
        let (code, raw) = env.receive(server, size: 40)
        #expect(code == MachMsgReturn.rcvTooLarge)
        let r = Received(raw)
        #expect(r.size == 24 && r.id == 78 && r.local == server && r.remote == 0)
        #expect(r.bits == 0x1100)  // COMPLEX cleared, local = send
        #expect(r.trailer(4) == 8)
        #expect(!env.ipc.messageQueued(on: server))
        #expect(env.ipc.portCounters(server)?.seqno == 1)
        #expect(env.ipc.portCounters(x)?.srights == 0)  // the body right was destroyed
        // The reply send-once right was destroyed: send-once notification.
        let (c2, raw2) = env.receive(reply)
        #expect(c2 == 0 && Received(raw2).id == MachNotify.sendOnce)
        // A buffer too small even for the bare header.
        #expect(env.send(m.bytes) == 0)
        #expect(env.receive(server, size: 16).0 == MachMsgReturn.rcvInvalidData)
        #expect(env.receive(0x55503).0 == MachMsgReturn.rcvInvalidName)
        #expect(env.receive(0x103).0 == MachMsgReturn.rcvInvalidName)
    }

    @Test func queueLimitTimeoutAndPseudoReceive() throws {
        let env = try IPCEnv()
        let (k, p) = env.construct(flags: MachPortConstruct.qlimit, qlimit: 1)
        #expect(k == 0)
        let reply = env.allocate()
        let m = TestMessage(remote: p, remoteDisposition: MachMsgType.makeSend, local: reply,
                            localDisposition: MachMsgType.makeSendOnce, id: 5)
        #expect(env.send(m.bytes) == 0)
        // Full: a send with a zero timeout fails at once and is pseudo-received.
        let start = Date()
        #expect(env.send(m.bytes, options: MachMsgOption.sendMsg | MachMsgOption.sendTimeout, timeout: 0)
                == MachMsgReturn.sendTimedOut)
        let back = Received(env.read(IPCEnv.sendBuffer, 24))
        #expect(back.bits == 0x1211)  // remote = send (17) not swapped, local = send-once (18)
        #expect(back.remote == p)  // MAKE_SEND became a real send right
        #expect(env.type(p) == (0, S | R) && env.urefs(p) == 1)
        #expect(env.type(back.local) == (0, SO))
        // A real timeout waits.
        #expect(env.send(TestMessage(remote: p, remoteDisposition: MachMsgType.copySend).bytes,
                         options: MachMsgOption.sendMsg | MachMsgOption.sendTimeout, timeout: 60)
                == MachMsgReturn.sendTimedOut)
        #expect(Date().timeIntervalSince(start) >= 0.05)
        // Send-once destinations ignore qlimit.
        #expect(env.send(TestMessage(remote: back.local, remoteDisposition: MachMsgType.moveSendOnce).bytes) == 0)
        #expect(env.ipc.portCounters(reply)?.msgcount == 1)
        // The default qlimit is 5.
        let q = env.allocate()
        for _ in 0..<5 { #expect(env.send(TestMessage(remote: q, remoteDisposition: MachMsgType.makeSend).bytes) == 0) }
        #expect(env.send(TestMessage(remote: q, remoteDisposition: MachMsgType.makeSend).bytes,
                         options: MachMsgOption.sendMsg | MachMsgOption.sendTimeout) == MachMsgReturn.sendTimedOut)
        #expect(env.ipc.portCounters(q)?.msgcount == 5)
    }

    @Test func pseudoReceiveReturnsMemoryAndPorts() throws {
        let env = try IPCEnv()
        let (_, p) = env.construct(flags: MachPortConstruct.qlimit, qlimit: 0)
        let region = try env.space.mapAnonymous(at: nil, size: 0x4000, protection: .readWrite, hint: nil)
        env.put([7, 7, 7, 7, 7, 7, 7, 7], at: region)
        let x = env.allocate()
        let m = TestMessage(remote: p, remoteDisposition: MachMsgType.makeSend,
                            descriptors: [TestMessage.ool(region, size: 8),
                                          TestMessage.port(x, MachMsgType.moveReceive)],
                            inline: [1, 2, 3, 4])
        #expect(env.send(m.bytes, options: MachMsgOption.sendMsg | MachMsgOption.sendTimeout) == MachMsgReturn.sendTimedOut)
        let back = Received(env.read(IPCEnv.sendBuffer, 128))
        #expect(back.bits == MachMsgBits.complex | 0x11 && back.remote == p && back.size == UInt32(m.bytes.count))
        let address = back.u64(28)
        #expect(address != 0 && address != region && env.read(address, 8) == [7, 7, 7, 7, 7, 7, 7, 7])
        let x2 = back.u32(28 + 16)
        #expect(env.type(x2) == (0, R) && back.raw[28 + 16 + 10] == 16)
        #expect(Array(back.raw[(28 + 28)..<(28 + 32)]) == [1, 2, 3, 4])
    }

    @Test func extractRightOfADeadNameAndVoucherOption() throws {
        let env = try IPCEnv()
        let dead = env.allocate(MachPortRight.deadName)
        let (kr, right, type) = env.lock.withLock { env.ipc.portExtractRight(dead, msgtName: MachMsgType.copySend) }
        #expect(kr == 0 && type == 17)
        if case .dead = right {} else { Issue.record("expected MACH_PORT_DEAD") }
        #expect(env.lock.withLock { env.ipc.portExtractRight(0, msgtName: 19).kr } == MachKern.invalidRight)
        #expect(env.lock.withLock { env.ipc.portExtractRight(dead, msgtName: 22).kr } == MachKern.invalidValue)
        // MACH_RCV_VOUCHER with no voucher: the field keeps the legacy value, bits have no voucher type.
        let (server, _) = ports(env)
        #expect(env.send(TestMessage(remote: server, remoteDisposition: MachMsgType.copySend, voucher: 0x77).bytes) == 0)
        let (code, raw) = env.receive(server, options: rcv | MachMsgOption.rcvVoucher)
        #expect(code == 0 && Received(raw).voucher == 0x77 && Received(raw).bits & MachMsgBits.voucherMask == 0)
        // A voucher disposition with name 0 is allowed and delivers 0.
        #expect(env.send(TestMessage(remote: server, remoteDisposition: MachMsgType.copySend,
                                     voucherDisposition: MachMsgType.copySend).bytes) == 0)
        #expect(Received(env.receive(server).1).voucher == 0)
    }

    /// What `p_machmsg` does, packed the way Ycode's `mach_msg` packs `mach_msg2`.
    @Test func machmsgProbeEquivalent() throws {
        let env = try IPCEnv()
        let rcvPort = env.allocate()
        #expect(env.insertRight(rcvPort, rcvPort, MachMsgType.makeSend) == 0)
        let extra = env.allocate()
        let payload = try env.space.mapAnonymous(at: nil, size: 0xC000, protection: .readWrite, hint: nil)
        env.put([UInt8](repeating: UInt8(ascii: "x"), count: 40000), at: payload)
        let m = TestMessage(remote: rcvPort, remoteDisposition: MachMsgType.copySend, id: 4242,
                            descriptors: [TestMessage.port(extra, MachMsgType.makeSend),
                                          TestMessage.ool(payload, size: 40000, copy: MachMsgDescriptor.virtualCopy)],
                            inline: le32(7))
        #expect(m.bytes.count == 60)
        let data = IPCEnv.sendBuffer
        env.put(m.bytes, at: data)
        let options = MachMsgOption.sendMsg | MachMsgOption.sendMQCall
        #expect(env.kr(-47, [data, options, UInt64(m.bits) | 60 << 32, UInt64(rcvPort), 4242 << 32, 2, 0, 0]) == 0)
        let rbuf = IPCEnv.receiveBuffer
        env.put([UInt8](repeating: 0, count: 68), at: rbuf)
        let ropts = MachMsgOption.rcvMsg | MachMsgOption.sendMQCall
        #expect(env.kr(-47, [rbuf, ropts, 0, 0, 0, UInt64(rcvPort) << 32, 68, 0]) == 0)
        let r = Received(env.read(rbuf, 68))
        #expect(r.id == 4242 && r.u32(56) == 7 && r.u32(28 + 12 + 12) == 40000 && r.u32(28) == extra)
        #expect(env.read(r.u64(40), 40000).allSatisfy { $0 == UInt8(ascii: "x") })
        #expect(r.trailer(4) == 8)
    }

    @Test func receiveTimeoutWaits() throws {
        let env = try IPCEnv()
        let p = env.allocate()
        let start = Date()
        #expect(env.receive(p, timeout: 50).0 == MachMsgReturn.rcvTimedOut)
        #expect(Date().timeIntervalSince(start) >= 0.045)
    }

    @Test func portSetReceiveRoundRobin() throws {
        let env = try IPCEnv()
        let a = env.allocate(), b = env.allocate(), set = env.allocate(MachPortRight.portSet)
        #expect(env.kr(-22, [env.task, UInt64(a), UInt64(set)]) == 0)
        #expect(env.kr(-22, [env.task, UInt64(b), UInt64(set)]) == 0)
        for (port, id) in [(a, 1), (b, 2), (a, 3), (b, 4)] {
            #expect(env.send(TestMessage(remote: port, remoteDisposition: MachMsgType.makeSend, id: Int32(id)).bytes) == 0)
        }
        #expect(env.ipc.messageQueued(on: set))
        var ids: [Int32] = []
        var locals: [UInt32] = []
        for _ in 0..<4 {
            let (code, raw) = env.receive(set)
            #expect(code == 0)
            ids.append(Received(raw).id)
            locals.append(Received(raw).local)
        }
        #expect(ids == [1, 2, 3, 4])
        #expect(locals == [a, b, a, b])
        #expect(env.receive(set).0 == MachMsgReturn.rcvTimedOut)
        // A member can still be received from directly.
        #expect(env.send(TestMessage(remote: a, remoteDisposition: MachMsgType.makeSend).bytes) == 0)
        #expect(env.receive(a).0 == 0)
    }

    @Test func sendThenReceiveToTheTaskPortMIG() throws {
        let env = try IPCEnv()
        let reply = env.allocate()
        // mach_port_allocate(RECEIVE) as a MIG request on the task port (3204).
        let m = TestMessage(remote: 0x103, remoteDisposition: MachMsgType.copySend, local: reply,
                            localDisposition: MachMsgType.makeSendOnce, id: 3204, inline: machNDRRecord + le32(1))
        env.put(m.bytes, at: IPCEnv.sendBuffer)
        let options = MachMsgOption.sendMsg | MachMsgOption.rcvMsg
        #expect(env.kr(-31, [IPCEnv.sendBuffer, options, UInt64(m.bytes.count), 0x100, UInt64(reply), 0, 0]) == 0)
        let r = Received(env.read(IPCEnv.sendBuffer, 0x100))
        #expect(r.id == 3304 && r.size == 40 && r.bits == 0x1200 && r.local == reply)
        #expect(r.u32(32) == 0)
        let name = r.u32(36)
        #expect(env.type(name) == (0, R))
        #expect(env.ipc.portCounters(reply)?.sorights == 0)
        // An unknown routine: MIG_BAD_ID in a 36-byte mig_reply_error_t.
        var bad = m
        bad.id = 3299
        env.put(bad.bytes, at: IPCEnv.sendBuffer)
        #expect(env.kr(-31, [IPCEnv.sendBuffer, options, UInt64(m.bytes.count), 0x100, UInt64(reply), 0, 0]) == 0)
        let r2 = Received(env.read(IPCEnv.sendBuffer, 0x100))
        #expect(r2.id == 3399 && r2.size == 36 && r2.u32(32) == MachKern.migBadID)
        // Wrong size: MIG_BAD_ARGUMENTS.
        var short = m
        short.inline = machNDRRecord
        env.put(short.bytes, at: IPCEnv.sendBuffer)
        #expect(env.kr(-31, [IPCEnv.sendBuffer, options, UInt64(short.bytes.count), 0x100, UInt64(reply), 0, 0]) == 0)
        #expect(Received(env.read(IPCEnv.sendBuffer, 0x100)).u32(32) == MachKern.migBadArguments)
        // Other kernel objects answer MIG_BAD_ID.
        var host = m
        host.remote = 0x303
        env.put(host.bytes, at: IPCEnv.sendBuffer)
        #expect(env.kr(-31, [IPCEnv.sendBuffer, options, UInt64(host.bytes.count), 0x100, UInt64(reply), 0, 0]) == 0)
        #expect(Received(env.read(IPCEnv.sendBuffer, 0x100)).u32(32) == MachKern.migBadID)
        #expect(env.urefs(0x103) == 1 && env.urefs(0x303) == 1)
    }

    @Test func migRoutinesOnTheTaskPort() throws {
        let env = try IPCEnv()
        let reply = env.allocate()
        func call(_ id: Int32, _ args: [UInt8], descriptors: [[UInt8]] = []) -> Received {
            let m = TestMessage(remote: 0x103, remoteDisposition: MachMsgType.copySend, local: reply,
                                localDisposition: MachMsgType.makeSendOnce, id: id, descriptors: descriptors,
                                inline: machNDRRecord + args)
            env.put(m.bytes, at: IPCEnv.sendBuffer)
            let k = env.kr(-31, [IPCEnv.sendBuffer, 3, UInt64(m.bytes.count), 0x200, UInt64(reply), 0, 0])
            #expect(k == 0)
            let r = Received(env.read(IPCEnv.sendBuffer, 0x200))
            #expect(r.id == id + 100)
            return r
        }
        let p = env.allocate()
        // get_refs / mod_refs / type.
        #expect(call(3208, le32(p) + le32(MachPortRight.receive) + le32(0)).u32(32) == 0)
        #expect(call(3201, le32(p)).u32(36) == R)
        #expect(call(3207, le32(p) + le32(MachPortRight.receive)).u32(36) == 1)
        #expect(call(3207, le32(p) + le32(MachPortRight.send)).u32(36) == 0)
        // set/get context.
        #expect(call(3229, le32(p) + le64(0xABCDEF)).u32(32) == 0)
        #expect(call(3228, le32(p)).u64(36) == 0xABCDEF)
        // set_attributes qlimit, then get it back.
        #expect(call(3218, le32(p) + le32(1) + le32(1) + le32(9)).u32(32) == 0)
        let attrs = call(3217, le32(p) + le32(1) + le32(17))
        #expect(attrs.u32(32) == 0 && attrs.u32(36) == 1 && attrs.u32(40) == 9)
        #expect(call(3218, le32(p) + le32(1) + le32(1) + le32(2000)).u32(32) == MachKern.invalidValue)
        // allocate_name, destroy.
        #expect(call(3203, le32(MachPortRight.receive) + le32(0x7703)).u32(32) == 0)
        #expect(env.type(0x7703) == (0, R))
        #expect(call(3203, le32(MachPortRight.receive) + le32(0x7703)).u32(32) == MachKern.nameExists)
        #expect(call(3205, le32(0x7703)).u32(32) == 0)
        #expect(env.type(0x7703).0 == MachKern.invalidName)
        // insert_right via a port descriptor (MAKE_SEND carried in the request).
        let ins = call(3214, le32(p), descriptors: [TestMessage.port(p, MachMsgType.makeSend)])
        #expect(ins.u32(32) == 0)
        #expect(env.type(p) == (0, S | R))
        // extract_right: a complex reply with the right.
        let ext = call(3215, le32(p) + le32(MachMsgType.makeSendOnce))
        #expect(ext.bits & MachMsgBits.complex != 0 && ext.size == 40)
        #expect(ext.raw[28 + 10] == 18 && env.type(ext.u32(28)) == (0, SO))
        // request_notification (complex request and reply).
        let n = env.allocate()
        let rn = call(3213, le32(p) + le32(UInt32(MachNotify.noSenders)) + le32(0),
                      descriptors: [TestMessage.port(n, MachMsgType.makeSendOnce)])
        #expect(rn.bits & MachMsgBits.complex != 0 && rn.u32(28) == 0)
        // special_reply_port_reset_link answers srp_lost_link = FALSE.
        let rl = call(3236, le32(p))
        #expect(rl.u32(32) == 0 && rl.u32(36) == 0)
        // construct (options inline) and guard/unguard.
        let cons = call(3231, le32(MachPortConstruct.insertSendRight) + le32(0) + [UInt8](repeating: 0, count: 24) + le64(0))
        #expect(cons.u32(32) == 0 && env.type(cons.u32(36)) == (0, S | R))
        #expect(call(3233, le32(cons.u32(36)) + le64(0x99) + le32(1)).u32(32) == 0)
        #expect(call(3234, le32(cons.u32(36)) + le64(0x99)).u32(32) == 0)
        #expect(call(3232, le32(cons.u32(36)) + le32(UInt32(bitPattern: -1)) + le64(0)).u32(32) == 0)
        #expect(env.type(cons.u32(36)).0 == MachKern.invalidName)
    }

    @Test func machMsg2Scalar() throws {
        let env = try IPCEnv()
        let (server, reply) = ports(env)
        let data = IPCEnv.sendBuffer
        env.put([UInt8](repeating: 0, count: 24) + [9, 8, 7, 6], at: data)
        func msg2(_ options: UInt64, bits: UInt32, size: UInt32, remote: UInt32, local: UInt32, id: Int32,
                  rcvName: UInt32 = 0, rcvSize: UInt32 = 0, timeout: UInt32 = 0) -> UInt32 {
            env.kr(-47, [data, options, UInt64(bits) | UInt64(size) << 32, UInt64(remote) | UInt64(local) << 32,
                         UInt64(UInt32(bitPattern: id)) << 32, UInt64(rcvName) << 32, UInt64(rcvSize), UInt64(timeout)])
        }
        let send = MachMsgOption.sendMsg | MachMsgOption.sendMQCall
        #expect(msg2(send, bits: 0x1513, size: 28, remote: server, local: reply, id: 42) == 0)
        let (code, raw) = env.receive(server)
        #expect(code == 0)
        let r = Received(raw)
        #expect(r.id == 42 && r.size == 28 && Array(raw[24..<28]) == [9, 8, 7, 6] && r.bits == 0x1112)
        // CFI: no call kind, or the wrong kind, is INVALID_OPTIONS.
        #expect(msg2(MachMsgOption.sendMsg, bits: 0x13, size: 24, remote: server, local: 0, id: 1)
                == MachMsgReturn.sendInvalidOptions)
        #expect(msg2(send | MachMsgOption.sendKobjectCall, bits: 0x13, size: 24, remote: server, local: 0, id: 1)
                == MachMsgReturn.sendInvalidOptions)
        // Kernel object with MQ_CALL: accepted (simulator processes are exempt
        // from rule 3 for kernel objects; their mach_msg() uses MQ_CALL here).
        #expect(msg2(send, bits: 0x13, size: 24, remote: 0x103, local: 0, id: 1) == 0)
        // Kernel object with DK_CALL: INVALID_OPTIONS after copyin, pseudo-received.
        let dk = MachMsgOption.sendMsg | MachMsgOption.sendDKCall
        #expect(msg2(dk, bits: 0x13, size: 24, remote: 0x103, local: 0, id: 1) == MachMsgReturn.sendInvalidOptions)
        #expect(env.urefs(0x103) == 2)  // the COPY_SEND came back as a real right
        #expect(env.r32(data + 8) == 0x103)
        // MQ_CALL to an ordinary port with KOBJECT_CALL: pseudo-received.
        let kobj = MachMsgOption.sendMsg | MachMsgOption.sendKobjectCall
        #expect(msg2(kobj, bits: 0x13, size: 24, remote: server, local: 0, id: 1) == MachMsgReturn.sendInvalidOptions)
        #expect(env.urefs(server) == 2)
        // A kobject call that is send-only with a reply port is refused.
        #expect(msg2(kobj, bits: 0x1513, size: 24, remote: 0x103, local: reply, id: 3204)
                == MachMsgReturn.sendInvalidOptions)
        // A simple message with a descriptor count is TOO_LARGE.
        #expect(env.kr(-47, [data, send, UInt64(0x13) | 24 << 32, UInt64(server), 0, 1, 0, 0])
                == MachMsgReturn.sendTooLarge)
        // Send then receive: MIG to the task port with KOBJECT_CALL.
        env.put([UInt8](repeating: 0, count: 24) + machNDRRecord + le32(MachPortRight.portSet), at: data)
        let rpc = MachMsgOption.sendMsg | MachMsgOption.rcvMsg | MachMsgOption.sendKobjectCall
        #expect(msg2(rpc, bits: 0x1513, size: 36, remote: 0x103, local: reply, id: 3204, rcvName: reply, rcvSize: 0x100) == 0)
        let answer = Received(env.read(data, 0x100))
        #expect(answer.id == 3304 && answer.u32(32) == 0)
        #expect(env.type(answer.u32(36)) == (0, MachPortType.portSet))
    }

    @Test func machMsg2VectorWithAux() throws {
        let env = try IPCEnv()
        let (server, _) = ports(env)
        let vecs = IPCEnv.scratch + 0x1000, message = IPCEnv.scratch + 0x1100, aux = IPCEnv.scratch + 0x1200
        env.put([UInt8](repeating: 0, count: 24) + [1, 2, 3, 4], at: message)
        env.put(le32(16) + le32(0) + [5, 6, 7, 8, 9, 10, 11, 12], at: aux)
        env.put(le64(message) + le64(0) + le32(28) + le32(0) + le64(aux) + le64(0) + le32(16) + le32(0), at: vecs)
        let options = MachMsgOption.sendMsg | MachMsgOption.sendMQCall | MachMsgOption.msgVector
        #expect(env.kr(-47, [vecs, options, 0x13 | 2 << 32, UInt64(server), 7 << 32, 0, 0, 0]) == 0)
        // Receive with two vectors.
        let rbuf = IPCEnv.scratch + 0x1400, raux = IPCEnv.scratch + 0x1500
        env.put(le64(0) + le64(rbuf) + le32(0) + le32(0x100) + le64(0) + le64(raux) + le32(0) + le32(64), at: vecs)
        let ropts = MachMsgOption.rcvMsg | MachMsgOption.rcvTimeout | MachMsgOption.msgVector
        #expect(env.kr(-47, [vecs, ropts, 0, 0, 0, UInt64(server) << 32, 2, 0]) == 0)
        #expect(Received(env.read(rbuf, 0x40)).id == 7)
        #expect(env.read(raux, 16) == le32(16) + le32(0) + [5, 6, 7, 8, 9, 10, 11, 12])
        // Errors.
        #expect(env.kr(-47, [vecs, options, 0x13, UInt64(server), 0, 0, 0, 0]) == MachMsgReturn.sendMsgTooSmall)
        #expect(env.kr(-47, [vecs, options, 0x13 | 3 << 32, UInt64(server), 0, 0, 0, 0]) == MachMsgReturn.sendInvalidData)
        env.put(le64(message) + le64(0) + le32(28) + le32(0) + le64(aux) + le64(0) + le32(4) + le32(0), at: vecs)
        #expect(env.kr(-47, [vecs, options, 0x13 | 2 << 32, UInt64(server), 0, 0, 0, 0]) == MachMsgReturn.sendAuxTooSmall)
        // An empty aux vector is no aux data (xnu): the send succeeds.
        env.put(le64(message) + le64(0) + le32(28) + le32(0) + le64(0) + le64(0) + le32(0) + le32(0), at: vecs)
        #expect(env.kr(-47, [vecs, options, 0x13 | 2 << 32, UInt64(server), 0, 0, 0, 0]) == 0)
        _ = env.receive(server)
        #expect(env.kr(-47, [vecs, ropts, 0, 0, 0, UInt64(server) << 32, 0, 0]) == MachMsgReturn.rcvInvalidArguments)
        #expect(env.kr(-47, [vecs, MachMsgOption.sendMsg | MachMsgOption.sendKobjectCall | MachMsgOption.msgVector,
                             0x13 | 1 << 32, UInt64(server), 0, 0, 0, 0]) == MachMsgReturn.sendInvalidOptions)
    }

    @Test func specialReplyPort() throws {
        let env = try IPCEnv()
        let (server, _) = ports(env)
        let srp = UInt32(env.trap(-50))
        #expect(env.type(srp) == (0, S | R) && env.urefs(srp) == 1)
        #expect(env.receiveTargetIsSpecial(srp))
        // Only send-once dispositions copy in.
        #expect(env.send(TestMessage(remote: srp, remoteDisposition: MachMsgType.copySend).bytes)
                == MachMsgReturn.sendInvalidDest)
        #expect(env.send(TestMessage(remote: server, remoteDisposition: MachMsgType.copySend, local: srp,
                                     localDisposition: MachMsgType.makeSend).bytes) == MachMsgReturn.sendInvalidReply)
        #expect(env.send(TestMessage(remote: server, remoteDisposition: MachMsgType.copySend,
                                     descriptors: [TestMessage.port(srp, MachMsgType.makeSendOnce)]).bytes)
                == MachMsgReturn.sendInvalidRight)
        #expect(env.send(TestMessage(remote: server, remoteDisposition: MachMsgType.copySend, local: srp,
                                     localDisposition: MachMsgType.makeSendOnce).bytes) == 0)
        let (_, raw) = env.receive(server)
        let so = Received(raw).remote
        // A send-once right to it may also be moved as a reply (libdispatch's
        // resend of a pseudo-received message; xnu ipc_right_copyin_check_reply).
        #expect(env.send(TestMessage(remote: server, remoteDisposition: MachMsgType.copySend, local: so,
                                     localDisposition: MachMsgType.moveSendOnce).bytes) == 0)
        let (_, raw2) = env.receive(server)
        let so2 = Received(raw2).remote
        #expect(env.send(TestMessage(remote: so2, remoteDisposition: MachMsgType.moveSendOnce, id: 9).bytes) == 0)
        // MACH_RCV_SYNC_WAIT: only on the thread's bound special reply port, with a valid destination.
        let sync = rcv | MachMsgOption.rcvSyncWait
        env.put([UInt8](repeating: 0, count: 64), at: IPCEnv.receiveBuffer)
        #expect(env.kr(-31, [IPCEnv.receiveBuffer, sync, 0, 0x100, UInt64(server), 0, UInt64(server)])
                == MachMsgReturn.rcvInvalidNotify)
        #expect(env.kr(-31, [IPCEnv.receiveBuffer, sync, 0, 0x100, UInt64(srp), 0, 0]) == MachMsgReturn.rcvInvalidNotify)
        #expect(env.kr(-31, [IPCEnv.receiveBuffer, sync, 0, 0x100, UInt64(srp), 0, UInt64(server)]) == 0)
        #expect(Received(env.read(IPCEnv.receiveBuffer, 64)).id == 9)
        // Another thread's receive with SYNC_WAIT on it fails.
        let other = ThreadContext(threadID: 2, portName: env.ipc.allocateThreadPort(), vcpuIndex: 1, kind: .pthread)
        #expect(env.kr(-31, [IPCEnv.receiveBuffer, sync, 0, 0x100, UInt64(srp), 0, UInt64(server)], context: other)
                == MachMsgReturn.rcvInvalidNotify)
    }

    /// xnu `mach_msg2_trap`: with MACH_RCV_SYNC_WAIT the link target is the
    /// header's remote port, also on a combined send and receive (libxpc's
    /// pipe routine through a special reply port, as xpcproxy_sim does).
    @Test func msg2CombinedSendReceiveWithSyncWait() throws {
        let env = try IPCEnv()
        let (server, _) = ports(env)
        let srp = UInt32(env.trap(-50))
        let msg = IPCEnv.receiveBuffer
        env.put([UInt8](repeating: 0, count: 64), at: msg)
        let options = MachMsgOption.sendMsg | MachMsgOption.sendMQCall | rcv | MachMsgOption.rcvSyncWait
        let bits = UInt64(MachMsgType.copySend) | UInt64(MachMsgType.makeSendOnce) << 8
        // Sent (the server holds the request), then the receive on the special
        // reply port waits for the reply and times out: no INVALID_NOTIFY.
        #expect(env.kr(-47, [msg, options, bits | 24 << 32, UInt64(server) | UInt64(srp) << 32, 0x55 << 32,
                             UInt64(srp) << 32, 64, 10]) == MachMsgReturn.rcvTimedOut)
        let (code, raw) = env.receive(server)
        #expect(code == 0 && Received(raw).id == 0x55)
        // A null remote port is still refused for a receive-only sync wait.
        #expect(env.kr(-47, [msg, rcv | MachMsgOption.rcvSyncWait, 0, 0, 0, UInt64(srp) << 32, 64, 10])
                == MachMsgReturn.rcvInvalidNotify)
    }

    @Test func sendToDeadDestinations() throws {
        let env = try IPCEnv()
        let p = env.allocate()
        #expect(env.insertRight(0x7003, p, MachMsgType.makeSendOnce) == 0)
        #expect(env.insertRight(p, p, MachMsgType.makeSend) == 0)
        #expect(env.insertRight(0x7103, p, MachMsgType.makeSendOnce) == 0)
        let n = env.allocate()
        #expect(env.requestNotification(0x7103, MachNotify.deadName, notify: n).0 == 0)
        // Move the receive right away into a message on q, then destroy q.
        let q = env.allocate()
        #expect(env.send(TestMessage(remote: q, remoteDisposition: MachMsgType.makeSend,
                                     descriptors: [TestMessage.port(p, MachMsgType.moveReceive)]).bytes) == 0)
        #expect(env.modRefs(q, MachPortRight.receive, -1) == 0)
        // A dead send-once destination without a request: success, destroyed.
        #expect(env.send(TestMessage(remote: 0x7003, remoteDisposition: MachMsgType.moveSendOnce).bytes) == 0)
        #expect(env.type(0x7003).0 == MachKern.invalidName)
        // With a request (it fired): the name is a dead name; INVALID_DEST.
        #expect(env.send(TestMessage(remote: 0x7103, remoteDisposition: MachMsgType.moveSendOnce).bytes)
                == MachMsgReturn.sendInvalidDest)
        #expect(env.type(0x7103) == (0, DN) && env.urefs(0x7103) == 2)
        // A dead send right as a destination: INVALID_DEST; as a reply: DEAD.
        #expect(env.send(TestMessage(remote: p, remoteDisposition: MachMsgType.copySend).bytes)
                == MachMsgReturn.sendInvalidDest)
        let r = env.allocate()
        #expect(env.send(TestMessage(remote: r, remoteDisposition: MachMsgType.makeSend, local: p,
                                     localDisposition: MachMsgType.moveSend).bytes) == 0)
        #expect(env.type(p).0 == MachKern.invalidName)  // the move consumed the only dead-name reference
        let (code, raw) = env.receive(r)
        #expect(code == 0 && Received(raw).remote == MachPortName.dead && Received(raw).bits == 0x1111)
    }
}

extension IPCEnv {
    func receiveTargetIsSpecial(_ name: UInt32) -> Bool { ipc.receiveTarget(of: name) == .specialReplyPort }
}
