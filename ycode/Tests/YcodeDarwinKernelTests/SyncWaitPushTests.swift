import Foundation
import Synchronization
import Testing
import YcodeDarwinABI
@testable import YcodeDarwinKernel

/// The sync-wait push (`YCODE_SYNC_PUSH`, scheduling-policy.md §4.10): a
/// synchronous request pushes its sender's class onto the image that will
/// receive it while it is queued, the receiving thread carries it once it is
/// received, the push ends with the sender's wait, and a change is passed on
/// along chains of such waits.
extension KernelSwitchSuites {
@Suite(.serialized) struct SyncWaitPushTests {
    /// Runs `body` with thread classes and the push on, restoring both.
    func with(depth: Int = 8, _ body: () throws -> Void) rethrows {
        schedSwitchesTestLock.lock()
        defer { schedSwitchesTestLock.unlock() }
        let saved = (SchedPolicy.qosEnabled, SchedPolicy.syncPushEnabled, SchedPolicy.syncPushDepth)
        SchedPolicy.qosEnabled = true
        SchedPolicy.syncPushEnabled = true
        SchedPolicy.syncPushDepth = depth
        defer { (SchedPolicy.qosEnabled, SchedPolicy.syncPushEnabled, SchedPolicy.syncPushDepth) = saved }
        try body()
    }

    /// Waits up to 5 s for `condition`.
    func eventually(_ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.005)
        }
        return condition()
    }

    /// A synchronous request from `t` (its thread `ctx`) to `remote`, the
    /// reply awaited on `reply` for at most `timeoutMs`, on its own host
    /// thread; the returned function waits for the trap's result.
    func request(_ w: SplitWorld, _ t: TaskWorld.Task, _ ctx: ThreadContext, remote: UInt32, reply: UInt32, id: Int32,
                 buffer: UInt64, timeoutMs: UInt32) -> () -> UInt32? {
        spawnThread {
            let m = TestMessage(remote: remote, remoteDisposition: MachMsgType.copySend, local: reply,
                                localDisposition: MachMsgType.makeSendOnce, id: id)
            return w.machMsg(t, ctx, m.bytes, at: buffer, rcvName: reply, rcvTimeoutMs: timeoutMs, fast: true).0
        }
    }

    /// Receives one request on `port` as `ctx` and answers it.
    func serve(_ w: SplitWorld, _ t: TaskWorld.Task, _ ctx: ThreadContext, port: UInt32, buffer: UInt64) -> Received? {
        let (code, r) = w.machMsg(t, ctx, nil, at: buffer, rcvName: port, rcvTimeoutMs: 5000, fast: true)
        guard code == 0 else { return nil }
        let answer = TestMessage(remote: r.remote, remoteDisposition: MachMsgType.moveSendOnce, id: r.id + 100)
        guard w.machMsg(t, ctx, answer.bytes, at: buffer, fast: true).0 == 0 else { return nil }
        return r
    }

    /// The port object behind `name` in `t`'s space.
    func port(_ t: TaskWorld.Task, _ name: UInt32) -> IPCPort? {
        t.ipc.lock.withLock { t.ipc.lookup(name).flatMap { t.ipc.entries[$0].port } }
    }

    @Test func aQueuedRequestPushesTheReceivingImageUntilItIsReceived() throws {
        try with {
            let w = SplitWorld()
            let rx = try w.add(pid: 200)
            let service = w.allocate(rx)
            let tx = try w.add(pid: 300)
            let name = w.give(service, from: rx, to: tx, disposition: MachMsgType.makeSend)
            let reply = w.allocate(tx)
            let ctx = w.thread(tx)
            ctx.schedClassStore.store(SchedClass.interactive, ordering: .relaxed)
            #expect(rx.kernel.syncPushClass == -1)
            let done = request(w, tx, ctx, remote: name, reply: reply, id: 7, buffer: SplitWorld.scratch + 0x2000, timeoutMs: 10_000)
            // Before any thread of the server receives, its image runs at the sender's class.
            #expect(eventually { rx.kernel.syncPushClass == SchedClass.interactive })
            let server = w.thread(rx)
            server.schedClassStore.store(SchedClass.background, ordering: .relaxed)
            #expect(server.hostClass == SchedClass.interactive)
            #expect(tx.kernel.syncPushClass == -1)
            let (code, r) = w.machMsg(rx, server, nil, at: SplitWorld.scratch + 0x8000, rcvName: service, rcvTimeoutMs: 5000, fast: true)
            #expect(code == 0 && r.id == 7)
            // Received: the image's push ends, the receiving thread carries it (§4.6).
            #expect(rx.kernel.syncPushClass == -1)
            #expect(server.ipcPushClass == SchedClass.interactive)
            let answer = TestMessage(remote: r.remote, remoteDisposition: MachMsgType.moveSendOnce, id: 8)
            #expect(w.machMsg(rx, server, answer.bytes, at: SplitWorld.scratch + 0x8000, fast: true).0 == 0)
            #expect(done() == 0)
            #expect(tx.kernel.syncWaiters.isEmpty && ctx.syncWait == nil)
            #expect(rx.kernel.syncPushPorts.isEmpty)
        }
    }

    @Test func theEndOfTheSendersWaitEndsThePush() throws {
        try with {
            let w = SplitWorld()
            let rx = try w.add(pid: 200)
            let service = w.allocate(rx)
            let tx = try w.add(pid: 300)
            let name = w.give(service, from: rx, to: tx, disposition: MachMsgType.makeSend)
            let reply = w.allocate(tx)
            let ctx = w.thread(tx)
            ctx.schedClassStore.store(SchedClass.utility, ordering: .relaxed)
            let done = request(w, tx, ctx, remote: name, reply: reply, id: 7, buffer: SplitWorld.scratch + 0x2000, timeoutMs: 300)
            #expect(eventually { rx.kernel.syncPushClass == SchedClass.utility })
            #expect(done() == MachMsgReturn.rcvTimedOut)
            // The request stays queued, without its push.
            #expect(rx.kernel.syncPushClass == -1)
            #expect(w.counters(rx, service)?.msgcount == 1)
            #expect(tx.kernel.syncWaiters.isEmpty)
            // Received later: no push is carried by a request nobody waits for.
            let server = w.thread(rx)
            server.schedClassStore.store(SchedClass.background, ordering: .relaxed)
            let (code, _) = w.machMsg(rx, server, nil, at: SplitWorld.scratch + 0x8000, rcvName: service, rcvTimeoutMs: 1000, fast: true)
            #expect(code == 0)
            #expect(rx.kernel.syncPushClass == -1)
        }
    }

    /// A waits on B while B's thread waits on C: A's class reaches C, and
    /// goes again when A's wait ends.
    @Test func aChainOfWaitsPassesThePushOn() throws {
        try with {
            let w = SplitWorld()
            let a = try w.add(pid: 400), b = try w.add(pid: 500), c = try w.add(pid: 600)
            let pb = w.allocate(b), pc = w.allocate(c)
            let bToC = w.give(pc, from: c, to: b, disposition: MachMsgType.makeSend)
            let aToB = w.give(pb, from: b, to: a, disposition: MachMsgType.makeSend)
            let rb = w.allocate(b), ra = w.allocate(a)
            let bt = w.thread(b), at = w.thread(a)
            bt.schedClassStore.store(SchedClass.background, ordering: .relaxed)
            at.schedClassStore.store(SchedClass.interactive, ordering: .relaxed)
            let bDone = request(w, b, bt, remote: bToC, reply: rb, id: 20, buffer: SplitWorld.scratch + 0x2000, timeoutMs: 10_000)
            #expect(eventually { c.kernel.syncPushClass == SchedClass.background })
            let aDone = request(w, a, at, remote: aToB, reply: ra, id: 10, buffer: SplitWorld.scratch + 0x2000, timeoutMs: 1500)
            #expect(eventually { b.kernel.syncPushClass == SchedClass.interactive })
            #expect(eventually { c.kernel.syncPushClass == SchedClass.interactive })
            #expect(aDone() == MachMsgReturn.rcvTimedOut)
            #expect(b.kernel.syncPushClass == -1)
            #expect(c.kernel.syncPushClass == SchedClass.background)
            // C answers B.
            let server = w.thread(c)
            #expect(serve(w, c, server, port: pc, buffer: SplitWorld.scratch + 0x8000)?.id == 20)
            #expect(bDone() == 0)
            #expect(c.kernel.syncPushClass == -1)
            #expect(SchedStats.syncPushChainUpdates.load(ordering: .relaxed) > 0)
        }
    }

    /// A request received by a thread that then waits on another image:
    /// a later rise of the first request reaches the second.
    @Test func aRiseReachesTheRequestOfTheServingThread() throws {
        try with {
            let w = SplitWorld()
            let a = try w.add(pid: 400), b = try w.add(pid: 500), c = try w.add(pid: 600)
            let pb = w.allocate(b), pc = w.allocate(c)
            let bToC = w.give(pc, from: c, to: b, disposition: MachMsgType.makeSend)
            let aToB = w.give(pb, from: b, to: a, disposition: MachMsgType.makeSend)
            let rb = w.allocate(b), ra = w.allocate(a)
            let at = w.thread(a), bt = w.thread(b)
            at.schedClassStore.store(SchedClass.default, ordering: .relaxed)
            bt.schedClassStore.store(SchedClass.background, ordering: .relaxed)
            let aDone = request(w, a, at, remote: aToB, reply: ra, id: 10, buffer: SplitWorld.scratch + 0x2000, timeoutMs: 10_000)
            #expect(eventually { b.kernel.syncPushClass == SchedClass.default })
            // B's thread receives A's request, then asks C (still waiting for A's answer).
            let (code, req) = w.machMsg(b, bt, nil, at: SplitWorld.scratch + 0x4000, rcvName: pb, rcvTimeoutMs: 5000, fast: true)
            #expect(code == 0 && req.id == 10)
            #expect(bt.ipcPushClass == SchedClass.default)
            let bDone = request(w, b, bt, remote: bToC, reply: rb, id: 20, buffer: SplitWorld.scratch + 0x6000, timeoutMs: 10_000)
            #expect(eventually { c.kernel.syncPushClass == SchedClass.default })
            // A's thread rises (a boost, a push of its own): its received request passes it on.
            at.schedClassStore.store(SchedClass.interactive, ordering: .relaxed)
            a.ipc.lock.withLock { a.ipc.repropagateSyncPush(a.kernel, depth: 0) }
            #expect(bt.ipcPushClass == SchedClass.interactive)
            #expect(c.kernel.syncPushClass == SchedClass.interactive)
            let server = w.thread(c)
            #expect(serve(w, c, server, port: pc, buffer: SplitWorld.scratch + 0x8000)?.id == 20)
            #expect(bDone() == 0)
            let answer = TestMessage(remote: req.remote, remoteDisposition: MachMsgType.moveSendOnce, id: 11)
            #expect(w.machMsg(b, bt, answer.bytes, at: SplitWorld.scratch + 0x4000, fast: true).0 == 0)
            #expect(aDone() == 0)
        }
    }

    /// The depth bound stops a change after the given number of hops.
    @Test func theDepthBoundStopsAChain() throws {
        try with(depth: 1) {
            let w = SplitWorld()
            let a = try w.add(pid: 400), b = try w.add(pid: 500), c = try w.add(pid: 600), d = try w.add(pid: 700)
            let pb = w.allocate(b), pc = w.allocate(c), pd = w.allocate(d)
            let aToB = w.give(pb, from: b, to: a, disposition: MachMsgType.makeSend)
            let bToC = w.give(pc, from: c, to: b, disposition: MachMsgType.makeSend)
            let cToD = w.give(pd, from: d, to: c, disposition: MachMsgType.makeSend)
            let ra = w.allocate(a), rb = w.allocate(b), rc = w.allocate(c)
            let at = w.thread(a), bt = w.thread(b), ct = w.thread(c)
            bt.schedClassStore.store(SchedClass.background, ordering: .relaxed)
            ct.schedClassStore.store(SchedClass.background, ordering: .relaxed)
            at.schedClassStore.store(SchedClass.interactive, ordering: .relaxed)
            let cDone = request(w, c, ct, remote: cToD, reply: rc, id: 30, buffer: SplitWorld.scratch + 0x2000, timeoutMs: 10_000)
            #expect(eventually { d.kernel.syncPushClass == SchedClass.background })
            let bDone = request(w, b, bt, remote: bToC, reply: rb, id: 20, buffer: SplitWorld.scratch + 0x2000, timeoutMs: 10_000)
            #expect(eventually { c.kernel.syncPushClass == SchedClass.background })
            let stops = SchedStats.syncPushDepthStops.load(ordering: .relaxed)
            let aDone = request(w, a, at, remote: aToB, reply: ra, id: 10, buffer: SplitWorld.scratch + 0x2000, timeoutMs: 1000)
            #expect(eventually { c.kernel.syncPushClass == SchedClass.interactive })
            // One hop (B's request to C) is passed on; C's request to D is not.
            #expect(d.kernel.syncPushClass == SchedClass.background)
            #expect(SchedStats.syncPushDepthStops.load(ordering: .relaxed) > stops)
            #expect(aDone() == MachMsgReturn.rcvTimedOut)
            #expect(serve(w, d, w.thread(d), port: pd, buffer: SplitWorld.scratch + 0x8000)?.id == 30)
            #expect(cDone() == 0)
            #expect(serve(w, c, w.thread(c), port: pc, buffer: SplitWorld.scratch + 0x8000)?.id == 20)
            #expect(bDone() == 0)
        }
    }

    /// A watch port given to a job at spawn pushes the job's image while the
    /// spawner still holds the receive right (an on-demand start); when the
    /// job is gone the push goes back to the holder.
    @Test func aWatchPortPushesTheJobItWasGivenTo() throws {
        try with {
            let w = SplitWorld()
            let launchd = try w.add(pid: 200)
            let job = try w.add(pid: 250)
            let tx = try w.add(pid: 300)
            let service = w.allocate(launchd)
            let name = w.give(service, from: launchd, to: tx, disposition: MachMsgType.makeSend)
            let reply = w.allocate(tx)
            let record = DarwinProcess(pid: 250, ppid: 200, pgid: 250, sid: 250, uniqueID: 9250,
                                       executablePath: "/usr/libexec/job", startTime: (0, 0))
            record.kernel = job.kernel
            let p = try #require(port(launchd, service))
            launchd.ipc.lock.withLock { launchd.ipc.bindSyncPushWatchPorts([p], to: record) }
            let ctx = w.thread(tx)
            ctx.schedClassStore.store(SchedClass.interactive, ordering: .relaxed)
            let done = request(w, tx, ctx, remote: name, reply: reply, id: 7, buffer: SplitWorld.scratch + 0x2000, timeoutMs: 1500)
            #expect(eventually { job.kernel.syncPushClass == SchedClass.interactive })
            #expect(launchd.kernel.syncPushClass == -1)
            // The job ends before it checks in: the credit goes back to the holder.
            record.state = .zombie
            launchd.ipc.lock.withLock { launchd.ipc.rebalanceSyncPush(p) }
            #expect(job.kernel.syncPushClass == -1)
            #expect(launchd.kernel.syncPushClass == SchedClass.interactive)
            #expect(done() == MachMsgReturn.rcvTimedOut)
            #expect(launchd.kernel.syncPushClass == -1)
        }
    }

    /// `YCODE_DEMAND_START_PUSH`: a job started with a message already on
    /// its watch port runs at the given class until that message is taken.
    @Test func anOnDemandStartIsPushedUntilItTakesTheMessage() throws {
        try with {
            let saved = SchedPolicy.demandStartClass
            SchedPolicy.demandStartClass = SchedClass.interactive
            defer { SchedPolicy.demandStartClass = saved }
            let w = SplitWorld()
            let launchd = try w.add(pid: 200)
            let job = try w.add(pid: 250)
            let tx = try w.add(pid: 300)
            let service = w.allocate(launchd)
            let name = w.give(service, from: launchd, to: tx, disposition: MachMsgType.makeSend)
            // An asynchronous message (no reply awaited): no push of its own.
            let m = TestMessage(remote: name, remoteDisposition: MachMsgType.copySend, id: 5)
            #expect(w.machMsg(tx, w.thread(tx), m.bytes, at: SplitWorld.scratch + 0x2000, fast: true).0 == 0)
            #expect(launchd.kernel.syncPushClass == -1)
            let record = DarwinProcess(pid: 250, ppid: 200, pgid: 250, sid: 250, uniqueID: 9251,
                                       executablePath: "/usr/libexec/job", startTime: (0, 0))
            record.kernel = job.kernel
            let p = try #require(port(launchd, service))
            launchd.ipc.lock.withLock { launchd.ipc.bindSyncPushWatchPorts([p], to: record) }
            #expect(job.kernel.syncPushClass == SchedClass.interactive)
            // The message is taken off the port: the push stays on the job
            // for the receiving thread's servicing episode, and ends with it.
            let server = w.thread(launchd)
            let (code, r) = w.machMsg(launchd, server, nil, at: SplitWorld.scratch + 0x8000, rcvName: service,
                                      rcvTimeoutMs: 1000, fast: true)
            #expect(code == 0 && r.id == 5)
            #expect(job.kernel.syncPushClass == SchedClass.interactive)
            #expect(p.demandPush == nil && server.demandServing != nil)
            let (next, _) = w.machMsg(launchd, server, nil, at: SplitWorld.scratch + 0x8000, rcvName: service,
                                      rcvTimeoutMs: 50, fast: true)
            #expect(next == MachMsgReturn.rcvTimedOut)
            #expect(job.kernel.syncPushClass == -1)
            #expect(launchd.kernel.syncPushClass == -1)
        }
    }

    /// `YCODE_DEMAND_START_MS`: the timed form lasts the bound from the spawn.
    @Test func aTimedOnDemandStartPushEndsAfterItsBound() throws {
        try with {
            let saved = (SchedPolicy.demandStartClass, SchedPolicy.demandStartNanoseconds)
            SchedPolicy.demandStartClass = SchedClass.interactive
            SchedPolicy.demandStartNanoseconds = 200_000_000
            defer { (SchedPolicy.demandStartClass, SchedPolicy.demandStartNanoseconds) = saved }
            let w = SplitWorld()
            let launchd = try w.add(pid: 200)
            let job = try w.add(pid: 250)
            let tx = try w.add(pid: 300)
            let service = w.allocate(launchd)
            let name = w.give(service, from: launchd, to: tx, disposition: MachMsgType.makeSend)
            let m = TestMessage(remote: name, remoteDisposition: MachMsgType.copySend, id: 5)
            #expect(w.machMsg(tx, w.thread(tx), m.bytes, at: SplitWorld.scratch + 0x2000, fast: true).0 == 0)
            let record = DarwinProcess(pid: 250, ppid: 200, pgid: 250, sid: 250, uniqueID: 9252,
                                       executablePath: "/usr/libexec/job", startTime: (0, 0))
            record.kernel = job.kernel
            let p = try #require(port(launchd, service))
            launchd.ipc.lock.withLock { launchd.ipc.bindSyncPushWatchPorts([p], to: record) }
            #expect(job.kernel.syncPushClass == SchedClass.interactive)
            #expect(p.demandPush == nil)
            Thread.sleep(forTimeInterval: 0.3)
            #expect(job.kernel.syncPushClass == -1)
        }
    }

    /// Off by default: a synchronous request makes no push record.
    @Test func offWithoutTheSwitch() throws {
        schedSwitchesTestLock.lock()
        defer { schedSwitchesTestLock.unlock() }
        let saved = (SchedPolicy.qosEnabled, SchedPolicy.syncPushEnabled)
        SchedPolicy.qosEnabled = true
        SchedPolicy.syncPushEnabled = false
        defer { (SchedPolicy.qosEnabled, SchedPolicy.syncPushEnabled) = saved }
        let w = SplitWorld()
        let rx = try w.add(pid: 200)
        let service = w.allocate(rx)
        let tx = try w.add(pid: 300)
        let name = w.give(service, from: rx, to: tx, disposition: MachMsgType.makeSend)
        let reply = w.allocate(tx)
        let ctx = w.thread(tx)
        ctx.schedClassStore.store(SchedClass.interactive, ordering: .relaxed)
        let done = request(w, tx, ctx, remote: name, reply: reply, id: 7, buffer: SplitWorld.scratch + 0x2000, timeoutMs: 300)
        #expect(done() == MachMsgReturn.rcvTimedOut)
        #expect(rx.kernel.syncPushClass == -1)
        #expect(w.counters(rx, service)?.msgcount == 1)
    }
}
}
