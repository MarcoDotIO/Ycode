import Foundation
import Testing
import YcodeDarwinABI
@testable import YcodeDarwinKernel

/// Asynchronous requests (scheduling-policy.md §4.11): a request's importance
/// lasts until it is answered (`YCODE_REPLY_IMPORTANCE`), and a queued
/// message's QoS overrides the workloop that drains its port
/// (`YCODE_ASYNC_QOS`).
extension KernelSwitchSuites {
@Suite(.serialized) struct AsyncRequestTests {
    func with(reply: Bool = false, asyncQoS: Bool = false, _ body: () throws -> Void) rethrows {
        schedSwitchesTestLock.lock()
        defer { schedSwitchesTestLock.unlock() }
        let saved = (SchedPolicy.holdEnabled, SchedPolicy.qosEnabled, SchedPolicy.replyImportanceEnabled, AsyncQoS.enabled)
        SchedPolicy.holdEnabled = true  // importance bookkeeping on
        SchedPolicy.qosEnabled = asyncQoS
        SchedPolicy.replyImportanceEnabled = reply
        AsyncQoS.enabled = asyncQoS
        defer { (SchedPolicy.holdEnabled, SchedPolicy.qosEnabled, SchedPolicy.replyImportanceEnabled, AsyncQoS.enabled) = saved }
        try body()
    }

    /// A server (an Adaptive daemon: an importance receiver) with a port that
    /// accepts importance, and a client (no process type: a donor) with a
    /// send right to it and a reply port.
    struct Pair {
        let w: TaskWorld
        let server: TaskWorld.Task, client: TaskWorld.Task
        let serverRecord: DarwinProcess, clientRecord: DarwinProcess
        let service: UInt32, clientService: UInt32, reply: UInt32
    }

    func pair() throws -> Pair {
        let w = TaskWorld()
        let s = try w.add(pid: 200), c = try w.add(pid: 300)
        let sr = record(s, pid: 200, path: "/usr/libexec/serverd", type: ProcessTypeCode.daemonAdaptive)
        // Kept: the kernel caches its record weakly.
        let cr = record(c, pid: 300, path: "/usr/libexec/clientd", type: 0)
        let service = w.allocate(s)
        w.system.lock.withLock { s.ipc.entries[s.ipc.lookup(service)!].port!.importanceDonation = true }
        #expect(w.insertRight(s, service, service, MachMsgType.makeSend) == 0)
        let clientService = w.give(service, from: s, to: c)
        let reply = w.allocate(c)
        return Pair(w: w, server: s, client: c, serverRecord: sr, clientRecord: cr, service: service, clientService: clientService, reply: reply)
    }

    func record(_ t: TaskWorld.Task, pid: Int32, path: String, type: UInt32) -> DarwinProcess {
        let p = DarwinProcess(pid: pid, ppid: 1, pgid: pid, sid: pid, uniqueID: UInt64(pid), executablePath: path, startTime: (0, 0))
        p.processType = type
        p.kernel = t.kernel
        t.kernel.schedProcessCache = p
        return p
    }

    func boosts(_ p: Pair) -> Int { p.w.system.lock.withLock { p.serverRecord.importanceBoosts } }

    /// The client sends a request (a send-once reply right to its reply
    /// port); the server receives it, then starts another receive (the end of
    /// its servicing episode, §4.3). Returns the reply right's name in the server.
    func requestAndReceive(_ p: Pair) -> UInt32 {
        let m = TestMessage(remote: p.clientService, remoteDisposition: MachMsgType.copySend, local: p.reply,
                            localDisposition: MachMsgType.makeSendOnce, id: 70)
        #expect(p.w.send(p.client, m.bytes) == 0)
        #expect(boosts(p) == 1)  // queued: the port credits the server (§4.3)
        let (k, r) = p.w.receive(p.server, p.service)
        #expect(k == 0 && r.id == 70)
        // The next receive ends the episode.
        #expect(p.w.receive(p.server, p.service).0 == MachMsgReturn.rcvTimedOut)
        return r.remote
    }

    @Test func withoutTheSwitchTheBoostEndsWithTheEpisode() throws {
        try with {
            let p = try pair()
            _ = requestAndReceive(p)
            #expect(boosts(p) == 0)
            #expect(p.w.system.lock.withLock { p.serverRecord.isDarwinBG })
        }
    }

    @Test func aRequestsBoostLastsUntilItsReplyIsSent() throws {
        try with(reply: true) {
            let p = try pair()
            let answered = SchedStats.replyBoostsAnswered.load(ordering: .relaxed)
            let replyName = requestAndReceive(p)
            #expect(boosts(p) == 1)
            #expect(p.w.system.lock.withLock { !p.serverRecord.isDarwinBG })
            // The reply, sent with the request's send-once right, ends it.
            let answer = TestMessage(remote: replyName, remoteDisposition: MachMsgType.moveSendOnce, id: 170)
            #expect(p.w.send(p.server, answer.bytes) == 0)
            #expect(boosts(p) == 0)
            #expect(SchedStats.replyBoostsAnswered.load(ordering: .relaxed) == answered + 1)
            #expect(p.w.receive(p.client, p.reply).1.id == 170)
        }
    }

    @Test func deallocatingTheReplyRightEndsTheBoost() throws {
        try with(reply: true) {
            let p = try pair()
            let replyName = requestAndReceive(p)
            #expect(boosts(p) == 1)
            #expect(p.w.kr(p.server, -18, [0x103, UInt64(replyName)]) == 0)  // mach_port_deallocate
            #expect(boosts(p) == 0)
            // The client gets the send-once notification.
            #expect(p.w.receive(p.client, p.reply).1.id == MachNotify.sendOnce)
        }
    }

    @Test func theReplyPortsDeathEndsTheBoost() throws {
        try with(reply: true) {
            let p = try pair()
            _ = requestAndReceive(p)
            #expect(boosts(p) == 1)
            // The client destroys its reply port's receive right.
            #expect(p.w.kr(p.client, -19, [0x103, UInt64(p.reply), 1, 0xFFFF_FFFF]) == 0)
            #expect(boosts(p) == 0)
        }
    }

    @Test func aMessageWithoutAReplyKeepsTheEpisodeRule() throws {
        try with(reply: true) {
            let p = try pair()
            let m = TestMessage(remote: p.clientService, remoteDisposition: MachMsgType.copySend, id: 71)
            #expect(p.w.send(p.client, m.bytes) == 0)
            #expect(boosts(p) == 1)
            #expect(p.w.receive(p.server, p.service).0 == 0)
            #expect(p.w.receive(p.server, p.service).0 == MachMsgReturn.rcvTimedOut)
            #expect(boosts(p) == 0)
        }
    }

    // MARK: The QoS of queued messages

    @Test func messageQoSFromTheSenderAndTheOverrideArgument() throws {
        try with(asyncQoS: true) {
            let ctx = ThreadContext(threadID: 9, portName: 0, vcpuIndex: 0, kind: .pthread)
            ctx.requestedQoS = 4
            var m = KMessage(complex: false, destination: .null, destinationType: 0, reply: .null, replyType: 0, id: 1)
            // No override: the sender's QoS stands for the voucher's priority.
            AsyncQoS.set(&m, sender: ctx, options: MachMsgOption.sendMsg, priority: 0)
            #expect(PthreadPriority.qos(m.ppriority) == 4 && m.qosOverride == 4)
            // A pthread priority as the override argument raises the override only.
            AsyncQoS.set(&m, sender: ctx, options: MachMsgOption.sendMsg | MachMsgOption.sendOverride,
                         priority: PthreadPriority.make(qos: 5))
            #expect(PthreadPriority.qos(m.ppriority) == 4 && m.qosOverride == 5)
            // The encoded form: QoS 3 with an override of 6.
            AsyncQoS.set(&m, sender: ctx, options: MachMsgOption.sendMsg | MachMsgOption.sendOverride,
                         priority: 3 << 16 | 6 << 20)
            #expect(PthreadPriority.qos(m.ppriority) == 3 && m.qosOverride == 6)
            // The queue keeps its highest override until that message leaves.
            var q = MessageQueue()
            var a = m, b = m
            a.qosOverride = 2
            b.qosOverride = 5
            q.append(a)
            q.append(b)
            #expect(q.maxOverride == 5)
            _ = q.popFirst()
            #expect(q.maxOverride == 5)
            _ = q.popFirst()
            #expect(q.maxOverride == 0)
        }
    }

    /// A message queued with a higher override than the knote's QoS raises
    /// the workloop's thread request, and the event carries the message's
    /// priority and override in `ext[2]`.
    @Test func aQueuedMessageRaisesTheWorkloopRequest() throws {
        for on in [false, true] {
            try with(asyncQoS: on) {
                let t = try T2Env()
                #expect(t.x0(367) == 0)
                let out = Env.scratch + 0x5000, msg = Env.scratch + 0x6000
                #expect(t.x0(UInt64(bitPattern: -16), [0x103, 1, out]) == 0)
                let port = UInt64(t.read(out, 4).readLE(UInt32.self, at: 0))
                #expect(t.x0(UInt64(bitPattern: -21), [0x103, port, port, 20]) == 0)  // MAKE_SEND
                // EV_ADD | EV_ENABLE | EV_DISPATCH, MACH_RCV_MSG, default QoS.
                let id: UInt64 = 0x7000_2000
                let kn = KEventRecord(ident: port, filter: -8, flags: 0x85, fflags: 0x2, qos: PthreadPriority.make(qos: 4),
                                      ext: [0, 0, 0, 0])
                let c = Env.scratch + 0x4000, o = Env.scratch + 0x5000
                t.put(kn.encoded(.qos), at: c)
                #expect(t.svc(375, [id, c, 1, o, 0, 0, 0, 0x400 | 0x2]).1.x[0] == 0)
                #expect(t.host.starts.isEmpty)
                // A send with MACH_SEND_OVERRIDE at user-initiated (encoded form).
                var header = [UInt8](repeating: 0, count: 24)
                header.putLE(UInt32(19), at: 0)  // COPY_SEND
                header.putLE(UInt32(24), at: 4)
                header.putLE(UInt32(port), at: 8)
                header.putLE(UInt32(0x42), at: 20)
                t.put(header, at: msg)
                #expect(t.x0(UInt64(bitPattern: -31), [msg, 0x21, 24, 0, 0, 0, 5 << 16]) == 0)
                let s = try #require(t.host.starts.first)
                #expect(s.state.x[4] & 0x7 == (on ? 5 : 4))
                let e = KEventRecord(decoding: t.read(s.state.x[3], KEventFormat.qos.size), at: 0, format: .qos)
                #expect(e.ident == port && e.fflags == 0)
                if on {
                    #expect(PthreadPriority.qos(UInt32(truncatingIfNeeded: e.ext[2] >> 32)) == 5)
                    #expect(PthreadPriority.qos(UInt32(truncatingIfNeeded: e.ext[2])) == 5)
                } else {
                    #expect(e.ext[2] == 0)
                }
            }
        }
    }
}
}
