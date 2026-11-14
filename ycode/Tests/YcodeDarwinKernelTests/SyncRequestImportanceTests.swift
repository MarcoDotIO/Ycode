import Foundation
import Testing
import YcodeDarwinABI
@testable import YcodeDarwinKernel

/// `YCODE_REPLY_IMPORTANCE=sync` (scheduling-policy.md §4.11, boot-profile.md
/// §27.3): a request whose sender waits for the reply keeps its importance
/// boost on the server until it is answered, past the receiving thread's
/// servicing episode (the work a handler hands to another queue then runs in
/// a boosted process, as xnu's voucher keeps it); a request nobody waits for
/// keeps §4.3's rule.
extension KernelSwitchSuites {
@Suite(.serialized) struct SyncRequestImportanceTests {
    func with(syncOnly: Bool, _ body: () throws -> Void) rethrows {
        schedSwitchesTestLock.lock()
        defer { schedSwitchesTestLock.unlock() }
        let saved = (SchedPolicy.holdEnabled, SchedPolicy.qosEnabled, SchedPolicy.syncPushEnabled, SchedPolicy.replyPushEnabled,
                     SchedPolicy.replyImportanceEnabled, SchedPolicy.replyImportanceSyncOnly)
        SchedPolicy.holdEnabled = true  // importance bookkeeping on
        SchedPolicy.qosEnabled = true
        SchedPolicy.syncPushEnabled = false
        SchedPolicy.replyPushEnabled = true
        SchedPolicy.replyImportanceEnabled = syncOnly
        SchedPolicy.replyImportanceSyncOnly = syncOnly
        defer {
            (SchedPolicy.holdEnabled, SchedPolicy.qosEnabled, SchedPolicy.syncPushEnabled, SchedPolicy.replyPushEnabled,
             SchedPolicy.replyImportanceEnabled, SchedPolicy.replyImportanceSyncOnly) = saved
        }
        try body()
    }

    /// A server (an Adaptive daemon, pid 200) whose service port accepts
    /// importance, and a client (a donor, pid 300) whose thread has a special
    /// reply port and an ordinary reply port.
    struct Pair {
        let w = SplitWorld()
        let rx: TaskWorld.Task, tx: TaskWorld.Task
        let serverRecord: DarwinProcess, clientRecord: DarwinProcess
        let service: UInt32, name: UInt32, reply: UInt32
        let client: ThreadContext, server: ThreadContext
        let srp: UInt32

        init() throws {
            rx = try w.add(pid: 200)
            tx = try w.add(pid: 300)
            serverRecord = DarwinProcess(pid: 200, ppid: 1, pgid: 200, sid: 200, uniqueID: 200, executablePath: "/usr/libexec/serverd", startTime: (0, 0))
            serverRecord.processType = ProcessTypeCode.daemonAdaptive
            serverRecord.kernel = rx.kernel
            rx.kernel.schedProcessCache = serverRecord
            clientRecord = DarwinProcess(pid: 300, ppid: 1, pgid: 300, sid: 300, uniqueID: 300, executablePath: "/usr/libexec/clientd", startTime: (0, 0))
            clientRecord.kernel = tx.kernel
            tx.kernel.schedProcessCache = clientRecord
            service = w.allocate(rx)
            let (w, rx, service) = (self.w, self.rx, self.service)
            w.system.lock.withLock { rx.ipc.entries[rx.ipc.lookup(service)!].port!.importanceDonation = true }
            name = w.give(service, from: rx, to: tx, disposition: MachMsgType.makeSend)
            reply = w.allocate(tx)
            client = w.thread(tx)
            client.schedClassStore.store(SchedClass.interactive, ordering: .relaxed)
            server = w.thread(rx)
            srp = UInt32(truncatingIfNeeded: w.trap(tx, client, -50, [], fast: false))
        }

        func boosts() -> Int { w.system.lock.withLock { serverRecord.importanceBoosts } }

        /// A request whose sender then waits: a send-once right to the special reply port.
        func sendSync(id: Int32) -> UInt32 {
            let m = TestMessage(remote: name, remoteDisposition: MachMsgType.copySend, local: srp,
                                localDisposition: MachMsgType.makeSendOnce, id: id)
            return w.machMsg(tx, client, m.bytes, at: SplitWorld.scratch + 0x2000, fast: true).0
        }

        /// A request nobody waits for: a send-once right to an ordinary port.
        func sendAsync(id: Int32) -> UInt32 {
            let m = TestMessage(remote: name, remoteDisposition: MachMsgType.copySend, local: reply,
                                localDisposition: MachMsgType.makeSendOnce, id: id)
            return w.machMsg(tx, client, m.bytes, at: SplitWorld.scratch + 0x2000, fast: true).0
        }

        func receiveAndEndEpisode() -> Received? {
            let (code, r) = w.machMsg(rx, server, nil, at: SplitWorld.scratch + 0x8000, rcvName: service, rcvTimeoutMs: 5000, fast: true)
            w.system.lock.withLock { rx.kernel.endServicing(server) }
            // The next receive also ends a §4.3 boost.
            _ = w.machMsg(rx, server, nil, at: SplitWorld.scratch + 0x8000, rcvName: service, rcvTimeoutMs: 1, fast: true)
            return code == 0 ? r : nil
        }

        func answer(_ r: Received) -> UInt32 {
            let m = TestMessage(remote: r.remote, remoteDisposition: MachMsgType.moveSendOnce, id: r.id + 100)
            return w.machMsg(rx, server, m.bytes, at: SplitWorld.scratch + 0x8000, fast: true).0
        }
    }

    @Test func aWaitedRequestKeepsItsBoostUntilAnswered() throws {
        try with(syncOnly: true) {
            let s = try Pair()
            #expect(s.sendSync(id: 7) == 0)
            #expect(s.boosts() == 1)  // queued
            let r = try #require(s.receiveAndEndEpisode())
            #expect(r.id == 7)
            #expect(s.boosts() == 1)
            #expect(s.w.system.lock.withLock { !s.serverRecord.isDarwinBG })
            #expect(s.answer(r) == 0)
            #expect(s.boosts() == 0)
            #expect(s.w.system.lock.withLock { s.serverRecord.isDarwinBG })
        }
    }

    @Test func aRequestNobodyWaitsForEndsWithTheEpisode() throws {
        try with(syncOnly: true) {
            let s = try Pair()
            #expect(s.sendAsync(id: 8) == 0)
            #expect(s.boosts() == 1)
            let r = try #require(s.receiveAndEndEpisode())
            #expect(r.id == 8)
            #expect(s.boosts() == 0)
            #expect(s.answer(r) == 0)
            #expect(s.boosts() == 0)
        }
    }

    @Test func offAWaitedRequestEndsWithTheEpisode() throws {
        try with(syncOnly: false) {
            let s = try Pair()
            #expect(s.sendSync(id: 9) == 0)
            let r = try #require(s.receiveAndEndEpisode())
            #expect(s.boosts() == 0)
            #expect(s.answer(r) == 0)
        }
    }
}
}
