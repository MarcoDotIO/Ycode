import Foundation
import Testing
import YcodeDarwinABI
@testable import YcodeDarwinKernel

/// `mach-ipc.md` §3: kernel notifications.
@Suite struct MachIPCNotificationTests {
    let S = MachPortType.send, R = MachPortType.receive, SO = MachPortType.sendOnce, DN = MachPortType.deadName

    func note(_ env: IPCEnv, _ port: UInt32) -> Received? {
        let (code, raw) = env.receive(port, options: MachMsgOption.rcvMsg | MachMsgOption.rcvTimeout | 3 << 24)
        return code == 0 ? Received(raw) : nil
    }

    @Test func sendOnceNotification() throws {
        let env = try IPCEnv()
        let p = env.allocate()
        #expect(env.insertRight(0x7003, p, MachMsgType.makeSendOnce) == 0)
        #expect(env.deallocate(0x7003) == 0)
        let n = try #require(note(env, p))
        #expect(n.id == MachNotify.sendOnce && n.size == 24 && n.bits == 0x1200 && n.local == p && n.remote == 0)
        #expect(n.trailer(12) == 0 && n.trailer(16) == 1)  // kernel sender
        #expect((0..<8).allSatisfy { n.trailer(20 + 4 * $0) == 0 })  // zero audit token
        #expect(env.ipc.portCounters(p)?.sorights == 0)
        // mod_refs(SEND_ONCE, −1) does the same.
        #expect(env.insertRight(0x7003, p, MachMsgType.makeSendOnce) == 0)
        #expect(env.modRefs(0x7003, MachPortRight.sendOnce, -1) == 0)
        #expect(note(env, p)?.id == MachNotify.sendOnce)
        // Not sent to a dead port.
        #expect(env.insertRight(0x7103, p, MachMsgType.makeSendOnce) == 0)
        #expect(env.modRefs(p, MachPortRight.receive, -1) == 0)
        #expect(env.deallocate(0x7103) == 0)
    }

    @Test func noSendersImmediateAndArmed() throws {
        let env = try IPCEnv()
        let p = env.allocate(), n = env.allocate()
        // srights 0 and sync <= mscount: fires at once, nothing stays armed.
        #expect(env.requestNotification(p, MachNotify.noSenders, sync: 0, notify: n) == (0, 0))
        let first = try #require(note(env, n))
        #expect(first.id == MachNotify.noSenders && first.u32(32) == 0)
        // Armed while senders exist; the previous request is returned.
        #expect(env.insertRight(p, p, MachMsgType.makeSend) == 0)
        #expect(env.requestNotification(p, MachNotify.noSenders, sync: 1, notify: n) == (0, 0))
        let (k, previous) = env.requestNotification(p, MachNotify.noSenders, sync: 1, notify: n)
        #expect(k == 0 && env.type(previous) == (0, SO))
        #expect(env.deallocate(previous) == 0)
        #expect(note(env, n)?.id == MachNotify.sendOnce)  // the old request's right, deallocated
        #expect(env.deallocate(p) == 0)
        let fired = try #require(note(env, n))
        #expect(fired.id == MachNotify.noSenders && fired.u32(32) == 1)
        #expect(note(env, n) == nil)
        // Port death with the request armed: a send-once notification instead.
        #expect(env.insertRight(p, p, MachMsgType.makeSend) == 0)
        #expect(env.requestNotification(p, MachNotify.noSenders, sync: 5, notify: n).0 == 0)
        #expect(env.modRefs(p, MachPortRight.receive, -1) == 0)
        #expect(note(env, n)?.id == MachNotify.sendOnce)
    }

    @Test func deadNameAndPortDeleted() throws {
        let env = try IPCEnv()
        let p = env.allocate(), n = env.allocate()
        #expect(env.insertRight(0x7003, p, MachMsgType.makeSendOnce) == 0)
        #expect(env.insertRight(0x7103, p, MachMsgType.makeSendOnce) == 0)
        #expect(env.requestNotification(0x7003, MachNotify.deadName, notify: n) == (0, 0))
        #expect(env.requestNotification(0x7103, MachNotify.deadName, notify: n) == (0, 0))
        #expect(env.type(0x7003) == (0, SO | MachPortType.dnRequest))
        // Freeing a watched name while the port lives: port-deleted.
        #expect(env.deallocate(0x7103) == 0)
        let deleted = try #require(note(env, n))
        #expect(deleted.id == MachNotify.portDeleted && deleted.size == 36 && deleted.u32(32) == 0x7103)
        #expect(note(env, p)?.id == MachNotify.sendOnce)
        // Port death: dead-name notification; the entry becomes a dead name with an extra reference.
        #expect(env.modRefs(p, MachPortRight.receive, -1) == 0)
        let dead = try #require(note(env, n))
        #expect(dead.id == MachNotify.deadName && dead.size == 36 && dead.u32(32) == 0x7003)
        #expect(Array(dead.raw[24..<32]) == machNDRRecord)
        #expect(env.type(0x7003) == (0, DN) && env.urefs(0x7003) == 2)
        // A request on a dead name is INVALID_ARGUMENT.
        #expect(env.requestNotification(0x7003, MachNotify.deadName, notify: n).0 == MachKern.invalidArgument)
    }

    @Test func portDeletedOnMove() throws {
        let env = try IPCEnv()
        let p = env.allocate(), n = env.allocate(), dst = env.allocate()
        #expect(env.insertRight(0x7003, p, MachMsgType.makeSendOnce) == 0)
        #expect(env.requestNotification(0x7003, MachNotify.deadName, notify: n).0 == 0)
        #expect(env.send(TestMessage(remote: dst, remoteDisposition: MachMsgType.makeSend,
                                     descriptors: [TestMessage.port(0x7003, MachMsgType.moveSendOnce)]).bytes) == 0)
        let deleted = try #require(note(env, n))
        #expect(deleted.id == MachNotify.portDeleted && deleted.u32(32) == 0x7003)
    }

    @Test func portDestroyedReturnsTheReceiveRight() throws {
        let env = try IPCEnv()
        let p = env.allocate(), n = env.allocate()
        #expect(env.insertRight(p, p, MachMsgType.makeSend) == 0)
        #expect(env.send(TestMessage(remote: p, remoteDisposition: MachMsgType.copySend, id: 11).bytes) == 0)
        #expect(env.requestNotification(p, MachNotify.portDestroyed, sync: 1, notify: n).0 == MachKern.invalidValue)
        #expect(env.requestNotification(p, MachNotify.portDestroyed, notify: n) == (0, 0))
        #expect(env.requestNotification(p, MachNotify.portDestroyed, notify: n).0 == MachKern.failure)
        #expect(env.ipc.portCounters(n)?.sorights == 1)
        // Destroying the receive right sends it away instead; the send right stays.
        #expect(env.modRefs(p, MachPortRight.receive, -1) == 0)
        #expect(env.type(p) == (0, S))
        let destroyed = try #require(note(env, n))
        #expect(destroyed.id == MachNotify.portDestroyed && destroyed.size == 40)
        #expect(destroyed.bits == 0x8000_1200)
        #expect(destroyed.u32(24) == 1 && destroyed.raw[28 + 10] == 16)
        let back = destroyed.u32(28)
        // The receive right merged back into p's entry; the queued message is intact.
        #expect(back == p && env.type(p) == (0, S | R))
        let (code, raw) = env.receive(p)
        #expect(code == 0 && Received(raw).id == 11)
        // Special reply ports refuse the registration.
        let srp = UInt32(env.trap(-50))
        #expect(env.requestNotification(srp, MachNotify.portDestroyed, notify: n).0 == MachKern.failure)
    }

    @Test func requestErrors() throws {
        let env = try IPCEnv()
        let p = env.allocate(), n = env.allocate()
        #expect(env.requestNotification(0, MachNotify.deadName, notify: n).0 == MachKern.invalidArgument)
        #expect(env.requestNotification(p, MachNotify.deadName, notify: MachPortName.dead).0
                == MachKern.invalidCapability)
        #expect(env.requestNotification(p, 99, notify: n).0 == MachKern.invalidValue)
        #expect(env.ipc.portCounters(n)?.sorights == 0)  // the copied-in right was released
        #expect(env.requestNotification(p, MachNotify.deadName, notify: n, poly: MachMsgType.makeSend).0
                == MachMsgReturn.sendInvalidDest)
        #expect(env.requestNotification(p, MachNotify.deadName, notify: 0x55503).0 == MachKern.invalidName)
        #expect(env.requestNotification(0x103, MachNotify.noSenders, notify: n).0 == MachKern.invalidRight)
        let set = env.allocate(MachPortRight.portSet)
        #expect(env.requestNotification(set, MachNotify.deadName, notify: n).0 == MachKern.invalidRight)
        // Send-possible fires at once.
        #expect(env.requestNotification(0x103, MachNotify.sendPossible, sync: 1, notify: n).0 == 0)
        #expect(note(env, n)?.id == MachNotify.sendPossible)
        // MOVE_SEND_ONCE of an existing send-once right as the notify right.
        #expect(env.insertRight(0x7003, n, MachMsgType.makeSendOnce) == 0)
        #expect(env.requestNotification(p, MachNotify.deadName, notify: 0x7003, poly: MachMsgType.moveSendOnce).0 == 0)
        #expect(env.type(0x7003).0 == MachKern.invalidName)
    }

    @Test func portDeathDestroysQueuedMessages() throws {
        let env = try IPCEnv()
        let p = env.allocate(), reply = env.allocate(), x = env.allocate()
        #expect(env.send(TestMessage(remote: p, remoteDisposition: MachMsgType.makeSend, local: reply,
                                     localDisposition: MachMsgType.makeSendOnce,
                                     descriptors: [TestMessage.port(x, MachMsgType.moveReceive)]).bytes) == 0)
        #expect(env.ipc.portCounters(reply)?.sorights == 1)
        #expect(env.modRefs(p, MachPortRight.receive, -1) == 0)
        // The reply right in the queued message: a send-once notification.
        #expect(note(env, reply)?.id == MachNotify.sendOnce)
        // The receive right in it was destroyed with it.
        #expect(env.ipc.nameCount == 5)  // task, thread, host, bootstrap, reply
    }

    @Test func taskPortRequestsUseTheSameRules() throws {
        let env = try IPCEnv()
        let n = env.allocate()
        let t = env.ipc.allocateThreadPort()
        #expect(env.requestNotification(t, MachNotify.deadName, notify: n).0 == 0)
        let context = ThreadContext(threadID: 9, portName: t, vcpuIndex: 2, kind: .pthread)
        #expect(env.modRefs(t, MachPortRight.send, 1) == 0)
        env.ipc.threadTerminated(context)
        let dead = try #require(note(env, n))
        #expect(dead.id == MachNotify.deadName && dead.u32(32) == t)
        #expect(env.type(t) == (0, DN) && env.urefs(t) == 2)
    }

    /// xnu `ipc_right_request_alloc` / `ipc_port_request_sparm` /
    /// `ipc_port_spnotify`: send-possible requests.
    @Test func sendPossibleDelayedArmedAndFired() throws {
        let env = try IPCEnv()
        let SP = MachPortType.spRequest, DELAYED = MachPortType.spRequestDelayed, DNR = MachPortType.dnRequest
        let n = env.allocate()
        let (_, p) = env.construct(flags: MachPortConstruct.qlimit | MachPortConstruct.insertSendRight, qlimit: 1)
        // sync = 0 on a queue with room: stored delayed, nothing fires (launchd_sim's request).
        #expect(env.requestNotification(p, MachNotify.sendPossible, sync: 0, notify: n) == (0, 0))
        #expect(note(env, n) == nil)
        #expect(env.type(p).1 & (DNR | SP | DELAYED) == DNR | SP | DELAYED)
        // Asking again returns the previous request's send-once right.
        let (k, previous) = env.requestNotification(p, MachNotify.sendPossible, sync: 0, notify: n)
        #expect(k == 0 && previous != 0 && env.type(previous) == (0, SO))
        #expect(env.deallocate(previous) == 0)
        #expect(note(env, n)?.id == MachNotify.sendOnce)
        // A receive does not fire a delayed request.
        #expect(env.send(TestMessage(remote: p, remoteDisposition: MachMsgType.copySend, id: 1).bytes) == 0)
        #expect(env.receive(p).0 == 0)
        #expect(note(env, n) == nil)
        // MACH_SEND_NOTIFY to a full queue arms it (the send itself times out).
        #expect(env.send(TestMessage(remote: p, remoteDisposition: MachMsgType.copySend, id: 2).bytes) == 0)
        let notifySend = MachMsgOption.sendMsg | MachMsgOption.sendTimeout | MachMsgOption.sendNotify
        #expect(env.send(TestMessage(remote: p, remoteDisposition: MachMsgType.copySend, id: 3).bytes,
                         options: notifySend) == MachMsgReturn.sendTimedOut)
        #expect(env.type(p).1 & (SP | DELAYED) == SP)
        // Receiving from the port fires it once.
        #expect(Received(env.receive(p).1).id == 2)
        let fired = try #require(note(env, n))
        #expect(fired.id == MachNotify.sendPossible && fired.size == 36 && fired.u32(32) == p)
        #expect(env.type(p).1 & (DNR | SP) == 0)
        #expect(note(env, n) == nil)
        // sync != 0: immediate when there is room, armed when full.
        #expect(env.requestNotification(p, MachNotify.sendPossible, sync: 1, notify: n).0 == 0)
        #expect(note(env, n)?.id == MachNotify.sendPossible)
        #expect(env.send(TestMessage(remote: p, remoteDisposition: MachMsgType.copySend, id: 4).bytes) == 0)
        #expect(env.requestNotification(p, MachNotify.sendPossible, sync: 1, notify: n).0 == 0)
        #expect(note(env, n) == nil && env.type(p).1 & (SP | DELAYED) == SP)
        #expect(env.receive(p).0 == 0)
        #expect(note(env, n)?.id == MachNotify.sendPossible)
        // A request still pending when the port dies becomes a dead-name notification.
        let q = env.allocate()
        #expect(env.insertRight(q, q, MachMsgType.makeSend) == 0)
        #expect(env.requestNotification(q, MachNotify.sendPossible, sync: 0, notify: n).0 == 0)
        #expect(env.modRefs(q, MachPortRight.receive, -1) == 0)
        let dead = try #require(note(env, n))
        #expect(dead.id == MachNotify.deadName && dead.u32(32) == q)
        // On a dead name: an immediate dead-name notification and one more reference.
        #expect(env.urefs(q) == 2)
        #expect(env.requestNotification(q, MachNotify.sendPossible, sync: 0, notify: n).0 == 0)
        #expect(note(env, n)?.id == MachNotify.deadName && env.urefs(q) == 3)
        // Destroying the name of a pending request: port-deleted.
        #expect(env.requestNotification(p, MachNotify.sendPossible, sync: 0, notify: n).0 == 0)
        #expect(env.lock.withLock { env.ipc.portDestroy(p) } == 0)
        var ids: [Int32] = []
        while let m = note(env, n) { ids.append(m.id) }
        #expect(ids == [MachNotify.portDeleted], "\(ids)")
    }
}
