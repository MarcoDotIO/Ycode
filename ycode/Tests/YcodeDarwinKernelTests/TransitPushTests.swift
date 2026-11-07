import Foundation
import Synchronization
import Testing
import YcodeDarwinABI
@testable import YcodeDarwinKernel

/// Pushes and importance through a port in transit (`YCODE_TRANSIT_PUSH`,
/// scheduling-policy.md §4.13): a client gives a server a new port's receive
/// right in a message to the server's listener and sends its request to the
/// new port before the server has taken that message. The request pushes,
/// and its importance boosts, whoever will receive the carrying message.
extension KernelSwitchSuites {
@Suite(.serialized) struct TransitPushTests {
    func with(transit: Bool, _ body: () throws -> Void) rethrows {
        schedSwitchesTestLock.lock()
        defer { schedSwitchesTestLock.unlock() }
        let saved = (SchedPolicy.qosEnabled, SchedPolicy.syncPushEnabled, SchedPolicy.replyPushEnabled, SchedPolicy.transitPushEnabled,
                     SchedPolicy.holdEnabled)
        SchedPolicy.qosEnabled = true
        SchedPolicy.syncPushEnabled = true
        SchedPolicy.replyPushEnabled = false
        SchedPolicy.transitPushEnabled = transit
        SchedPolicy.holdEnabled = true  // importance bookkeeping
        defer {
            (SchedPolicy.qosEnabled, SchedPolicy.syncPushEnabled, SchedPolicy.replyPushEnabled, SchedPolicy.transitPushEnabled,
             SchedPolicy.holdEnabled) = saved
        }
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

    struct Setup {
        let w: SplitWorld
        let server: TaskWorld.Task, client: TaskWorld.Task
        let listener: UInt32, connection: UInt32, reply: UInt32
        let clientThread: ThreadContext
    }

    /// The server's listener, the client's send right to it, and a connection
    /// port whose receive right the client sends to the listener (keeping a
    /// send right): the right is in transit until the server receives.
    func connect() throws -> Setup {
        let w = SplitWorld()
        let server = try w.add(pid: 200), client = try w.add(pid: 300)
        let listener = w.allocate(server)
        let toListener = w.give(listener, from: server, to: client, disposition: MachMsgType.makeSend)
        let connection = w.allocate(client)
        _ = w.give(connection, from: client, to: client, disposition: MachMsgType.makeSend)
        let ctx = w.thread(client)
        let hello = TestMessage(remote: toListener, remoteDisposition: MachMsgType.copySend, id: 1,
                                descriptors: [TestMessage.port(connection, MachMsgType.moveReceive)])
        #expect(w.machMsg(client, ctx, hello.bytes, at: SplitWorld.scratch + 0x1000, fast: true).0 == 0)
        return Setup(w: w, server: server, client: client, listener: listener, connection: connection, reply: w.allocate(client),
                     clientThread: ctx)
    }

    /// A synchronous request on the connection, its reply awaited for at most `timeoutMs`.
    func request(_ s: Setup, timeoutMs: UInt32) -> () -> UInt32? {
        let (w, t, ctx, connection, reply) = (s.w, s.client, s.clientThread, s.connection, s.reply)
        return spawnThread {
            let m = TestMessage(remote: connection, remoteDisposition: MachMsgType.copySend, local: reply,
                                localDisposition: MachMsgType.makeSendOnce, id: 7)
            return w.machMsg(t, ctx, m.bytes, at: SplitWorld.scratch + 0x2000, rcvName: reply, rcvTimeoutMs: timeoutMs, fast: true).0
        }
    }

    @Test func aRequestOnAPortInTransitPushesTheReceiverOfTheCarryingMessage() throws {
        try with(transit: true) {
            let s = try connect()
            s.clientThread.schedClassStore.store(SchedClass.interactive, ordering: .relaxed)
            let done = request(s, timeoutMs: 10_000)
            #expect(eventually { s.server.kernel.syncPushClass == SchedClass.interactive })
            #expect(SchedStats.transitCredits.load(ordering: .relaxed) >= 0)
            // The server takes the carrying message: the right lands in its space, the credit stays.
            let srv = s.w.thread(s.server)
            srv.schedClassStore.store(SchedClass.background, ordering: .relaxed)
            #expect(srv.hostClass == SchedClass.interactive)
            let (code, hello) = s.w.machMsg(s.server, srv, nil, at: SplitWorld.scratch + 0x8000, rcvName: s.listener,
                                            rcvTimeoutMs: 1000, fast: true)
            #expect(code == 0 && hello.id == 1)
            let connection = hello.u32(28)
            #expect(s.server.kernel.syncPushClass == SchedClass.interactive)
            // It serves the request: the receiving thread carries the push, then the answer ends it.
            let (code2, r) = s.w.machMsg(s.server, srv, nil, at: SplitWorld.scratch + 0x8000, rcvName: connection,
                                         rcvTimeoutMs: 1000, fast: true)
            #expect(code2 == 0 && r.id == 7)
            #expect(s.server.kernel.syncPushClass == -1)
            #expect(srv.ipcPushClass == SchedClass.interactive)
            let answer = TestMessage(remote: r.remote, remoteDisposition: MachMsgType.moveSendOnce, id: 8)
            #expect(s.w.machMsg(s.server, srv, answer.bytes, at: SplitWorld.scratch + 0x8000, fast: true).0 == 0)
            #expect(done() == 0)
            #expect(s.server.kernel.syncPushPorts.isEmpty)
        }
    }

    @Test func withoutTheSwitchARequestOnAPortInTransitPushesNobody() throws {
        try with(transit: false) {
            let s = try connect()
            s.clientThread.schedClassStore.store(SchedClass.interactive, ordering: .relaxed)
            let done = request(s, timeoutMs: 300)
            Thread.sleep(forTimeInterval: 0.1)
            #expect(s.server.kernel.syncPushClass == -1)
            #expect(done() == MachMsgReturn.rcvTimedOut)
        }
    }

    /// The right leaves the space that queued requests credited: the credit
    /// goes with it into transit, to the receiver of the carrying message.
    @Test func aCreditFollowsTheRightIntoTransit() throws {
        try with(transit: true) {
            let w = SplitWorld()
            let a = try w.add(pid: 200), b = try w.add(pid: 300), c = try w.add(pid: 400)
            let port = w.allocate(a)
            let toPort = w.give(port, from: a, to: c, disposition: MachMsgType.makeSend)
            let listener = w.allocate(b)
            let toListener = w.give(listener, from: b, to: a, disposition: MachMsgType.makeSend)
            let reply = w.allocate(c)
            let ct = w.thread(c)
            ct.schedClassStore.store(SchedClass.default, ordering: .relaxed)
            let done = spawnThread {
                let m = TestMessage(remote: toPort, remoteDisposition: MachMsgType.copySend, local: reply,
                                    localDisposition: MachMsgType.makeSendOnce, id: 7)
                return w.machMsg(c, ct, m.bytes, at: SplitWorld.scratch + 0x2000, rcvName: reply, rcvTimeoutMs: 1500, fast: true).0
            }
            #expect(eventually { a.kernel.syncPushClass == SchedClass.default })
            // A gives the receive right away in a message to B's listener.
            let at = w.thread(a)
            let give = TestMessage(remote: toListener, remoteDisposition: MachMsgType.copySend, id: 2,
                                   descriptors: [TestMessage.port(port, MachMsgType.moveReceive)])
            #expect(w.machMsg(a, at, give.bytes, at: SplitWorld.scratch + 0x1000, fast: true).0 == 0)
            #expect(a.kernel.syncPushClass == -1)
            #expect(b.kernel.syncPushClass == SchedClass.default)
            #expect(done() == MachMsgReturn.rcvTimedOut)
            #expect(b.kernel.syncPushClass == -1)
        }
    }

    /// A connection port in transit in a message to a launchd service port
    /// whose job is spawned only afterwards: the binding of the watch port
    /// moves the in-transit request's credit from launchd to the job.
    @Test func aWatchPortBoundLaterTakesTheCreditOfAPortInTransit() throws {
        try with(transit: true) {
            let w = SplitWorld()
            let launchd = try w.add(pid: 200), job = try w.add(pid: 250), tx = try w.add(pid: 300)
            let service = w.allocate(launchd)
            let toService = w.give(service, from: launchd, to: tx, disposition: MachMsgType.makeSend)
            let connection = w.allocate(tx)
            _ = w.give(connection, from: tx, to: tx, disposition: MachMsgType.makeSend)
            let ctx = w.thread(tx)
            let hello = TestMessage(remote: toService, remoteDisposition: MachMsgType.copySend, id: 1,
                                    descriptors: [TestMessage.port(connection, MachMsgType.moveReceive)])
            #expect(w.machMsg(tx, ctx, hello.bytes, at: SplitWorld.scratch + 0x1000, fast: true).0 == 0)
            let reply = w.allocate(tx)
            ctx.schedClassStore.store(SchedClass.interactive, ordering: .relaxed)
            let done = spawnThread {
                let m = TestMessage(remote: connection, remoteDisposition: MachMsgType.copySend, local: reply,
                                    localDisposition: MachMsgType.makeSendOnce, id: 7)
                return w.machMsg(tx, ctx, m.bytes, at: SplitWorld.scratch + 0x2000, rcvName: reply, rcvTimeoutMs: 1500, fast: true).0
            }
            #expect(eventually { launchd.kernel.syncPushClass == SchedClass.interactive })
            let record = DarwinProcess(pid: 250, ppid: 200, pgid: 250, sid: 250, uniqueID: 9250,
                                       executablePath: "/usr/libexec/job", startTime: (0, 0))
            record.kernel = job.kernel
            let p = try #require(launchd.ipc.lock.withLock { launchd.ipc.lookup(service).flatMap { launchd.ipc.entries[$0].port } })
            launchd.ipc.lock.withLock { launchd.ipc.bindSyncPushWatchPorts([p], to: record) }
            #expect(job.kernel.syncPushClass == SchedClass.interactive)
            #expect(launchd.kernel.syncPushClass == -1)
            #expect(done() == MachMsgReturn.rcvTimedOut)
            #expect(job.kernel.syncPushClass == -1)
        }
    }

    /// `YCODE_WATCH_PUSH`: with the reply push alone, spawns bind watch ports
    /// for the queued credit only with the switch.
    @Test func watchPortCreditNeedsTheSwitchWithTheReplyPushAlone() {
        schedSwitchesTestLock.lock()
        defer { schedSwitchesTestLock.unlock() }
        let saved = (SchedPolicy.qosEnabled, SchedPolicy.syncPushEnabled, SchedPolicy.replyPushEnabled, SchedPolicy.watchPushEnabled)
        defer { (SchedPolicy.qosEnabled, SchedPolicy.syncPushEnabled, SchedPolicy.replyPushEnabled, SchedPolicy.watchPushEnabled) = saved }
        SchedPolicy.qosEnabled = true
        SchedPolicy.syncPushEnabled = false
        SchedPolicy.replyPushEnabled = true
        SchedPolicy.watchPushEnabled = false
        #expect(!SchedPolicy.watchPortCreditActive)
        SchedPolicy.watchPushEnabled = true
        #expect(SchedPolicy.watchPortCreditActive)
        SchedPolicy.replyPushEnabled = false
        #expect(!SchedPolicy.watchPortCreditActive)
        SchedPolicy.syncPushEnabled = true
        #expect(SchedPolicy.watchPortCreditActive)
    }

    /// Importance (§4.3): a donor's message to a port in transit boosts the
    /// importance receiver bound to the listener.
    @Test func importanceOnAPortInTransitBoostsTheListenersReceiver() throws {
        try with(transit: true) {
            let w = TaskWorld()
            let s = try w.add(pid: 200), c = try w.add(pid: 300)
            let sr = DarwinProcess(pid: 200, ppid: 1, pgid: 200, sid: 200, uniqueID: 200, executablePath: "/usr/libexec/serverd", startTime: (0, 0))
            sr.processType = ProcessTypeCode.daemonAdaptive
            sr.kernel = s.kernel
            s.kernel.schedProcessCache = sr
            let cr = DarwinProcess(pid: 300, ppid: 1, pgid: 300, sid: 300, uniqueID: 300, executablePath: "/usr/libexec/clientd", startTime: (0, 0))
            cr.kernel = c.kernel
            c.kernel.schedProcessCache = cr
            let listener = w.allocate(s)
            #expect(w.insertRight(s, listener, listener, MachMsgType.makeSend) == 0)
            let toListener = w.give(listener, from: s, to: c)
            let connection = w.allocate(c)
            #expect(w.insertRight(c, connection, connection, MachMsgType.makeSend) == 0)
            w.system.lock.withLock { c.ipc.entries[c.ipc.lookup(connection)!].port!.importanceDonation = true }
            let hello = TestMessage(remote: toListener, remoteDisposition: MachMsgType.copySend, id: 1,
                                    descriptors: [TestMessage.port(connection, MachMsgType.moveReceive)])
            #expect(w.send(c, hello.bytes) == 0)
            let before = w.system.lock.withLock { sr.importanceBoosts }
            let m = TestMessage(remote: connection, remoteDisposition: MachMsgType.copySend, id: 70)
            #expect(w.send(c, m.bytes) == 0)
            #expect(w.system.lock.withLock { sr.importanceBoosts } == before + 1)
            // Received by the server: the boost moves with the message as before (§4.3).
            let (k, r) = w.receive(s, listener)
            #expect(k == 0 && r.id == 1)
            #expect(w.system.lock.withLock { sr.importanceBoosts } == before + 1)
            let (k2, r2) = w.receive(s, r.u32(28))
            #expect(k2 == 0 && r2.id == 70)
            _ = cr
        }
    }
}
}
