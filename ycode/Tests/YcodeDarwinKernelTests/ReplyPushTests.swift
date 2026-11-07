import Foundation
import Synchronization
import Testing
import YcodeDarwinABI
@testable import YcodeDarwinKernel

/// The reply push (`YCODE_REPLY_PUSH`, scheduling-policy.md §4.12): a request
/// whose sender waits for the reply pushes the sender's class onto the image
/// that holds it, from the send to the reply: queued, then received and held
/// in the receiving space until the send-once reply right leaves it; also in
/// libdispatch's two-call form (a send on the thread's special reply port, then
/// a receive with MACH_RCV_SYNC_WAIT).
extension KernelSwitchSuites {
@Suite(.serialized) struct ReplyPushTests {
    func with(_ body: () throws -> Void) rethrows {
        schedSwitchesTestLock.lock()
        defer { schedSwitchesTestLock.unlock() }
        let saved = (SchedPolicy.qosEnabled, SchedPolicy.syncPushEnabled, SchedPolicy.replyPushEnabled)
        SchedPolicy.qosEnabled = true
        SchedPolicy.syncPushEnabled = false
        SchedPolicy.replyPushEnabled = true
        defer { (SchedPolicy.qosEnabled, SchedPolicy.syncPushEnabled, SchedPolicy.replyPushEnabled) = saved }
        try body()
    }

    func eventually(_ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.005)
        }
        return condition()
    }

    /// A client (pid 300) with a send right to a server's (pid 200) service
    /// port, its thread at class ui with a special reply port.
    struct Pair {
        let w = SplitWorld()
        let rx: TaskWorld.Task, tx: TaskWorld.Task
        let service: UInt32, name: UInt32
        let client: ThreadContext, server: ThreadContext
        let srp: UInt32

        init() throws {
            rx = try w.add(pid: 200)
            service = w.allocate(rx)
            tx = try w.add(pid: 300)
            name = w.give(service, from: rx, to: tx, disposition: MachMsgType.makeSend)
            client = w.thread(tx)
            client.schedClassStore.store(SchedClass.interactive, ordering: .relaxed)
            server = w.thread(rx)
            server.schedClassStore.store(SchedClass.background, ordering: .relaxed)
            srp = UInt32(truncatingIfNeeded: w.trap(tx, client, -50, [], fast: false))
        }

        /// The request, sent alone with a send-once right to the special reply port.
        func send(id: Int32) -> UInt32 {
            let m = TestMessage(remote: name, remoteDisposition: MachMsgType.copySend, local: srp,
                                localDisposition: MachMsgType.makeSendOnce, id: id)
            return w.machMsg(tx, client, m.bytes, at: SplitWorld.scratch + 0x2000, fast: true).0
        }

        /// The client's receive with MACH_RCV_SYNC_WAIT on its special reply port.
        func awaitReply(timeoutMs: UInt32) -> UInt32 {
            let options = MachMsgOption.rcvMsg | MachMsgOption.rcvSyncWait | MachMsgOption.rcvTimeout
            return w.kr(tx, client, -31, [SplitWorld.scratch + 0x2000, options, 0, 0x200, UInt64(srp), UInt64(timeoutMs),
                                          UInt64(name)], fast: true)
        }

        /// The server's thread takes the request.
        func receive() -> Received? {
            let (code, r) = w.machMsg(rx, server, nil, at: SplitWorld.scratch + 0x8000, rcvName: service, rcvTimeoutMs: 5000, fast: true)
            return code == 0 ? r : nil
        }

        /// The push the server side holds: its image's, or its threads' held requests.
        func heldClass(_ others: [ThreadContext] = []) -> Int {
            ([server] + others).map { t in HeldPushCounter.maxClass(t.schedPushes.withLock { $0.held }) }
                .reduce(rx.kernel.syncPushClass, max)
        }

        func answer(_ r: Received) -> UInt32 {
            let m = TestMessage(remote: r.remote, remoteDisposition: MachMsgType.moveSendOnce, id: r.id + 100)
            return w.machMsg(rx, server, m.bytes, at: SplitWorld.scratch + 0x8000, fast: true).0
        }
    }

    @Test func aSpecialReplyRequestPushesTheServerUntilItIsAnswered() throws {
        try with {
            let s = try Pair()
            #expect(s.send(id: 7) == 0)
            // Queued: the server's image runs at the client's class.
            #expect(s.rx.kernel.syncPushClass == SchedClass.interactive)
            #expect(s.client.replyWait != nil)
            let r = try #require(s.receive())
            #expect(r.id == 7)
            // Received (by a thread that services no workloop): that thread holds
            // the push past its servicing episode; the image is not pushed.
            s.w.system.lock.withLock { s.rx.kernel.endServicing(s.server) }
            #expect(s.rx.kernel.syncPushClass == -1)
            #expect(s.heldClass() == SchedClass.interactive)
            #expect(s.server.hostClass == SchedClass.interactive)
            // Answered: the push ends; the client's wait returns with the reply.
            #expect(s.answer(r) == 0)
            #expect(s.heldClass() == -1)
            #expect(s.awaitReply(timeoutMs: 1000) == 0)
            #expect(s.client.replyWait == nil && s.tx.kernel.syncWaiters.isEmpty)
            #expect(SchedStats.replyPushesAnswered.load(ordering: .relaxed) > 0)
        }
    }

    @Test func theReplyRightGoingEndsThePush() throws {
        try with {
            let s = try Pair()
            #expect(s.send(id: 7) == 0)
            let r = try #require(s.receive())
            #expect(s.heldClass() == SchedClass.interactive)
            // The server drops the reply right without answering.
            #expect(s.w.kr(s.rx, s.server, -18, [0x103, UInt64(r.remote)], fast: false) == 0)
            #expect(s.heldClass() == -1)
            // The client learns of it through its receive (a send-once notification).
            _ = s.awaitReply(timeoutMs: 200)
            #expect(s.client.replyWait == nil)
        }
    }

    @Test func theEndOfTheClientsWaitEndsAHeldPush() throws {
        try with {
            let s = try Pair()
            #expect(s.send(id: 7) == 0)
            let r = try #require(s.receive())
            #expect(s.heldClass() == SchedClass.interactive)
            // The client gives up: the server, still holding the request, is not pushed any more.
            #expect(s.awaitReply(timeoutMs: 50) == MachMsgReturn.rcvTimedOut)
            #expect(s.heldClass() == -1)
            #expect(s.client.replyWait == nil)
            // The late answer changes nothing.
            #expect(s.answer(r) == 0)
            #expect(s.heldClass() == -1)
        }
    }

    @Test func aOneCallRequestIsHeldUntilItIsAnswered() throws {
        try with {
            let s = try Pair()
            let reply = s.w.allocate(s.tx)
            let done = spawnThread {
                let m = TestMessage(remote: s.name, remoteDisposition: MachMsgType.copySend, local: reply,
                                    localDisposition: MachMsgType.makeSendOnce, id: 9)
                return s.w.machMsg(s.tx, s.client, m.bytes, at: SplitWorld.scratch + 0x4000, rcvName: reply, rcvTimeoutMs: 10_000, fast: true).0
            }
            #expect(eventually { s.rx.kernel.syncPushClass == SchedClass.interactive })
            let r = try #require(s.receive())
            s.w.system.lock.withLock { s.rx.kernel.endServicing(s.server) }
            #expect(s.server.ipcPushClass == -1)
            #expect(s.heldClass() == SchedClass.interactive)
            #expect(s.answer(r) == 0)
            #expect(done() == 0)
            #expect(s.heldClass() == -1)
        }
    }

    /// A server that holds a client's request and asks a third image passes
    /// the client's class on: its host class carries the held push (§4.10).
    @Test func aHeldRequestPassesThePushAlongAChain() throws {
        try with {
            let s = try Pair()
            let c = try s.w.add(pid: 600)
            let pc = s.w.allocate(c)
            let bToC = s.w.give(pc, from: c, to: s.rx, disposition: MachMsgType.makeSend)
            #expect(s.send(id: 7) == 0)
            let r = try #require(s.receive())
            // The server's thread asks C on its own special reply port, at its own class (bg).
            let srp2 = UInt32(truncatingIfNeeded: s.w.trap(s.rx, s.server, -50, [], fast: false))
            let m = TestMessage(remote: bToC, remoteDisposition: MachMsgType.copySend, local: srp2,
                                localDisposition: MachMsgType.makeSendOnce, id: 20)
            #expect(s.w.machMsg(s.rx, s.server, m.bytes, at: SplitWorld.scratch + 0x6000, fast: true).0 == 0)
            // Its class is the client's (the held push), so C is pushed at it.
            #expect(c.kernel.syncPushClass == SchedClass.interactive)
            #expect(s.answer(r) == 0)
            // The client's push is gone from the server; the server's own request keeps the class it was sent with.
            #expect(s.heldClass() == -1)
            #expect(c.kernel.syncPushClass == SchedClass.interactive)
        }
    }

    /// A rise of the waiting thread's own class (here a sync-IPC push, as a
    /// ulock owner's push would be) reaches its request, and its end goes too.
    @Test func theWaitingThreadsClassChangesReachItsRequest() throws {
        try with {
            let s = try Pair()
            s.client.threadDarwinBG = true
            s.w.system.lock.withLock { s.tx.kernel.refreshSchedClass(s.client) }
            #expect(s.client.schedClass == SchedClass.background)
            #expect(s.send(id: 7) == 0)
            #expect(s.rx.kernel.syncPushClass == SchedClass.background)
            s.client.ipcPushClass = SchedClass.interactive
            s.w.system.lock.withLock { s.tx.kernel.refreshSchedClass(s.client) }
            #expect(s.rx.kernel.syncPushClass == SchedClass.interactive)
            let r = try #require(s.receive())
            #expect(s.heldClass() == SchedClass.interactive)
            s.client.ipcPushClass = -1
            s.w.system.lock.withLock { s.tx.kernel.refreshSchedClass(s.client) }
            #expect(s.heldClass() == SchedClass.background)
            #expect(s.answer(r) == 0)
            #expect(s.heldClass() == -1)
        }
    }

    /// The server moves the reply right on as the reply of a message to one
    /// of its own ports (as libdispatch re-sends a pseudo-received request):
    /// the push goes with it and is held again where that message is received.
    @Test func aMovedReplyRightTakesThePushAlong() throws {
        try with {
            let s = try Pair()
            let inner = s.w.allocate(s.rx)
            #expect(s.send(id: 7) == 0)
            let r = try #require(s.receive())
            #expect(s.heldClass() == SchedClass.interactive)
            let forward = TestMessage(remote: inner, remoteDisposition: MachMsgType.makeSend, local: r.remote,
                                      localDisposition: MachMsgType.moveSendOnce, id: 8)
            #expect(s.w.machMsg(s.rx, s.server, forward.bytes, at: SplitWorld.scratch + 0x8000, fast: true).0 == 0)
            // Queued on the inner port: still credited to the server's image.
            #expect(s.rx.kernel.syncPushClass == SchedClass.interactive)
            let other = s.w.thread(s.rx)
            let (code, r2) = s.w.machMsg(s.rx, other, nil, at: SplitWorld.scratch + 0xA000, rcvName: inner, rcvTimeoutMs: 5000, fast: true)
            #expect(code == 0 && r2.id == 8)
            s.w.system.lock.withLock { s.rx.kernel.endServicing(other) }
            #expect(s.heldClass([other]) == SchedClass.interactive)
            #expect(s.heldClass() == -1 || HeldPushCounter.maxClass(s.server.schedPushes.withLock { $0.held }) == -1)
            // The answer through the moved right ends it.
            let answer = TestMessage(remote: r2.remote, remoteDisposition: MachMsgType.moveSendOnce, id: 9)
            #expect(s.w.machMsg(s.rx, other, answer.bytes, at: SplitWorld.scratch + 0xA000, fast: true).0 == 0)
            #expect(s.heldClass([other]) == -1)
            #expect(s.awaitReply(timeoutMs: 1000) == 0)
            #expect(SchedStats.replyPushesMoved.load(ordering: .relaxed) > 0)
        }
    }

    /// `YCODE_REPLY_PUSH=image`: the whole receiving image holds the push.
    @Test func theWholeImageFormPushesTheImage() throws {
        try with {
            SchedPolicy.replyPushWholeImage = true
            defer { SchedPolicy.replyPushWholeImage = false }
            let s = try Pair()
            #expect(s.send(id: 7) == 0)
            let r = try #require(s.receive())
            s.w.system.lock.withLock { s.rx.kernel.endServicing(s.server) }
            #expect(s.rx.kernel.syncPushClass == SchedClass.interactive)
            #expect(HeldPushCounter.maxClass(s.server.schedPushes.withLock { $0.held }) == -1)
            #expect(s.answer(r) == 0)
            #expect(s.rx.kernel.syncPushClass == -1)
        }
    }

    /// A workloop's held requests push whichever thread services it.
    @Test func aWorkloopsHeldPushFollowsItsServicer() throws {
        try with {
            let s = try Pair()
            let a = s.w.thread(s.rx), b = s.w.thread(s.rx)
            for t in [a, b] {
                t.threadDarwinBG = true
                s.w.system.lock.withLock { s.rx.kernel.refreshSchedClass(t) }
                #expect(t.schedClass == SchedClass.background)
            }
            let c = HeldPushCounter()
            s.w.system.lock.withLock { c.attach(a) }
            s.w.system.lock.withLock { c.change(KernelLock.unit(SchedClass.interactive), sign: 1) }
            #expect(a.schedClass == SchedClass.interactive)
            // Another thread takes over the workloop: the push goes with the workloop.
            s.w.system.lock.withLock { c.detach(a); c.attach(b) }
            #expect(a.schedClass == SchedClass.background)
            #expect(b.schedClass == SchedClass.interactive)
            s.w.system.lock.withLock { c.change(KernelLock.unit(SchedClass.interactive), sign: -1) }
            #expect(b.schedClass == SchedClass.background)
        }
    }

    @Test func offByDefaultNothingIsHeld() throws {
        schedSwitchesTestLock.lock()
        defer { schedSwitchesTestLock.unlock() }
        let saved = (SchedPolicy.qosEnabled, SchedPolicy.syncPushEnabled, SchedPolicy.replyPushEnabled)
        SchedPolicy.qosEnabled = true
        SchedPolicy.syncPushEnabled = false
        SchedPolicy.replyPushEnabled = false
        defer { (SchedPolicy.qosEnabled, SchedPolicy.syncPushEnabled, SchedPolicy.replyPushEnabled) = saved }
        let s = try Pair()
        #expect(s.send(id: 7) == 0)
        #expect(s.rx.kernel.syncPushClass == -1)
        #expect(s.client.replyWait == nil)
        let r = try #require(s.receive())
        #expect(s.rx.kernel.syncPushClass == -1)
        #expect(s.answer(r) == 0)
    }
}
}
