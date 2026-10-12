import Foundation
import Testing
import YcodeDarwinABI
@testable import YcodeDarwinKernel

/// The workqueue and kevent (stage4a-contract.md §5; threads-and-events.md
/// §2, §3), with a fake vCPU pool and real host threads.
@Suite(.serialized) struct WorkqueueKEventTests {
    // Upcall flags.
    static let newSPI: UInt64 = 0x4_0000, prioQoS: UInt64 = 0x4000, overcommit: UInt64 = 0x1_0000,
               reuse: UInt64 = 0x2_0000, kevent: UInt64 = 0x8_0000, manager: UInt64 = 0x10_0000,
               tsdSet: UInt64 = 0x20_0000, workloop: UInt64 = 0x40_0000
    // KEVENT_FLAG_*.
    static let immediate: UInt64 = 1, errorEvents: UInt64 = 2, workq: UInt64 = 0x20, wlFlag: UInt64 = 0x400
    static let legacy: UInt32 = 0x8FF

    func open(_ t: T2Env) {
        #expect(t.x0(367) == 0)
    }

    func put(_ t: T2Env, _ events: [KEventRecord], at va: UInt64, format: KEventFormat = .qos) {
        t.put(events.flatMap { $0.encoded(format) }, at: va)
    }

    func events(_ t: T2Env, at va: UInt64, count: Int, format: KEventFormat = .qos) -> [KEventRecord] {
        let b = t.read(va, count * format.size)
        return (0..<count).map { KEventRecord(decoding: b, at: $0 * format.size, format: format) }
    }

    /// kevent_qos on the workqueue kqueue (register only), as libdispatch does.
    @discardableResult
    func registerWorkq(_ t: T2Env, _ changes: [KEventRecord], out: Int = 0, context: ThreadContext? = nil) -> TrapFrame {
        let c = Env.scratch + 0x2000, o = Env.scratch + 0x3000
        put(t, changes, at: c)
        return t.svc(374, [UInt64.max, c, UInt64(changes.count), o, UInt64(out), 0, 0,
                           Self.workq | Self.immediate | Self.errorEvents], context: context).1
    }

    /// A worker's return; runs on its own host thread when it may park.
    func workerReturn(_ t: T2Env, _ ctx: ThreadContext, op: UInt64 = 4, changes: UInt64 = 0, count: UInt64 = 0)
        -> () -> (DarwinKernel.Outcome, TrapFrame)? {
        t.spawn { t.svc(368, [op, changes, count, 0], context: ctx) }
    }

    // MARK: Workqueue

    @Test func setupOps() throws {
        let t = try T2Env()
        #expect(t.x0(368, [0x20, 0, 1, UInt64(Self.legacy)]) == 22)  // REQTHREADS before workq_open
        var rec = [UInt8](repeating: 0, count: 24)
        rec.putLE(UInt32(2), at: 0)
        rec.putLE(UInt64(0x58), at: 8)
        rec.putLE(UInt64(0x60), at: 16)
        t.put(rec, at: Env.scratch + 0x100)
        #expect(t.x0(368, [0x400, Env.scratch + 0x100, 24, 0]) == 0)  // SETUP_DISPATCH before workq_open
        #expect(t.kernel.workqueue.dispatchConfig?.labelOffset == 0x60)
        rec.putLE(UInt32(1), at: 4)
        t.put(rec, at: Env.scratch + 0x100)
        #expect(t.x0(368, [0x400, Env.scratch + 0x100, 24, 0]) == 45)
        open(t)
        #expect(t.x0(367) == 0)  // idempotent
        #expect(t.x0(368, [0x10, 0, 0x58, 1]) == 0)  // NEWSPISUPP
        #expect(t.x0(368, [0x30, 0, 1, UInt64(Self.legacy)]) == 45)  // REQTHREADS2
        #expect(t.x0(368, [0x20, 0, 0, UInt64(Self.legacy)]) == 22)  // count 0
        #expect(t.x0(368, [0x20, 0, 1, 0xFF]) == 22)  // no QoS
        #expect(t.x0(368, [0x80, 0, UInt64(Self.legacy), 0]) == 0)  // SET_EVENT_MANAGER_PRIORITY
        #expect(t.x0(368, [0x200, 0, UInt64(Self.legacy), 0]) == 22)  // SHOULD_NARROW from a non-worker
        #expect(t.x0(368, [0x4, 0, 0, 0]) == 22)  // THREAD_RETURN from a non-worker
        #expect(t.x0(368, [0x999, 0, 0, 0]) == 22)
        // bsdthread_ctl.
        #expect(t.x0(478, [0x800, 4, 0, 0]) == 8)
        #expect(t.x0(478, [0x100, UInt64(Self.legacy), 0, 0x10]) == 22)  // KEVENT_UNBIND from a non-worker
        #expect(t.x0(478, [0x100, UInt64(Self.legacy), 0, 0x01]) == 0)
        #expect(t.x0(478, [0x10, 0, 0, 0]) == 45)
    }

    @Test func reqThreadsStartsAWorkerWithTheSpecLayout() throws {
        let t = try T2Env()
        open(t)
        #expect(t.x0(368, [0x20, 0, 1, UInt64(Self.legacy)]) == 0)
        let s = try #require(t.host.starts.first)
        let ctx = s.context
        #expect(ctx.kind == .workqueue && ctx.portName & 3 == 3)
        let me = s.state.x[0]
        let base = me - (540 << 10)
        #expect(s.state.pc == T2Env.wqStart)
        #expect(s.state.x[1] == UInt64(ctx.portName) && s.state.x[2] == base + (16 << 10))
        #expect(s.state.x[3] == 0 && s.state.x[5] == 0)
        #expect(s.state.x[4] == Self.newSPI | Self.prioQoS | 4 | Self.tsdSet)
        #expect(s.state.sp == me && s.state.tpidrro == me + 224)
        #expect(s.state.x[6...].allSatisfy { $0 == 0 })
        t.kernel.lock.withLock {
            let r = t.space.region(containing: base)
            #expect(r?.protection == [])  // guard page
            #expect(t.space.region(containing: base + 0x4000)?.protection == .readWrite)
            #expect(t.space.region(containing: base + (560 << 10) - 1) != nil)
        }
        #expect(t.kernel.workqueueThreads.map(\.threadID) == [ctx.threadID])
        #expect(t.x0(372, context: ctx) == ctx.threadID)
    }

    @Test func admissionRuleAndBlockedWorkerFreesASlot() throws {
        let t = try T2Env()
        open(t)
        #expect(t.x0(368, [0x20, 0, 20, UInt64(Self.legacy)]) == 0)
        #expect(t.host.starts.count == 8)  // parallelism 8 per QoS
        #expect(t.x0(368, [0x20, 0, 3, 0x8000_0000 | UInt64(Self.legacy)]) == 0)
        #expect(t.host.starts.count == 11)  // overcommit: always
        #expect(t.host.starts[10].state.x[4] & Self.overcommit != 0)
        #expect(t.x0(368, [0x20, 0, 2, 0x4FF]) == 0)
        #expect(t.host.starts.count == 13)  // another QoS bucket
        // A constrained worker blocks in the kernel: another one starts.
        let blocker = t.host.starts[0].context
        let w = Env.scratch + 0x800
        t.put32(0, at: w)
        let wait = t.spawn { t.x0(515, [0x0100_0001, w, 0, 0], context: blocker) }
        #expect(t.eventually { t.host.starts.count == 14 })
        #expect(t.host.starts[13].state.x[4] & 0xFFF == 4)
        // SHOULD_NARROW from a constrained worker: "no".
        #expect(t.x0(368, [0x200, 0, UInt64(Self.legacy), 0], context: t.host.starts[1].context) == 0)
        t.svc(516, [0x0100_0101, w, 0])
        #expect(wait() == 0)
    }

    @Test func returnTakesTheNextRequestParksAndIsReused() throws {
        let t = try T2Env()
        open(t)
        t.svc(368, [0x20, 0, 1, UInt64(Self.legacy)])
        let ctx = t.host.starts[0].context
        // Another request is queued behind the parallelism limit? No: queue one
        // more and return: the same thread takes it, restarted with REUSE.
        t.kernel.lock.withLock { t.kernel.workqueue.plainPending[.init(qos: 5, overcommit: false)] = 1 }
        let (o, f) = t.svc(368, [4, 0, 0, 0], context: ctx)
        #expect(o == .resume)
        #expect(f.elr == T2Env.wqStart && f.x[0] == t.host.starts[0].state.x[0])
        #expect(f.x[4] == Self.newSPI | Self.prioQoS | 5 | Self.reuse)
        // Nothing left: it parks.
        let parked = workerReturn(t, ctx)
        #expect(t.eventually { t.kernel.idleWorkqueueThreads.contains { $0 === ctx } })
        // A new request goes to the idle worker; no new thread starts.
        t.svc(368, [0x20, 0, 1, 0x10FF])
        let (o2, f2) = try #require(parked())
        #expect(o2 == .resume && f2.x[4] == Self.newSPI | Self.prioQoS | 5 | Self.reuse)
        #expect(t.host.starts.count == 1)
    }

    @Test func idleWorkerExits() throws {
        let t = try T2Env()
        open(t)
        t.kernel.lock.withLock { t.kernel.workqueue.idleTimeoutNanoseconds = 30_000_000 }
        t.svc(368, [0x20, 0, 1, 0x10FF])
        let ctx = t.host.starts[0].context
        let (o, f) = try #require(workerReturn(t, ctx)())
        #expect(o == .resume)
        #expect(f.x[5] == UInt64.max && f.x[3] == 0)
        #expect(f.x[4] == Self.newSPI | Self.prioQoS | 4 | Self.reuse)  // QoS capped at legacy
        // The library exits it with bsdthread_terminate (the whole region).
        let base = f.x[0] - (540 << 10)
        let (o2, _) = t.svc(361, [base, 560 << 10, UInt64(ctx.portName), 0], context: ctx)
        #expect(o2 == .threadExit)
        #expect(!t.isMapped(base + 0x8000))
        #expect(t.kernel.workqueueThreads.isEmpty)
    }

    // MARK: kevent on the workqueue kqueue

    @Test func userEventWakesTheManager() throws {
        let t = try T2Env()
        open(t)
        let mgr: UInt32 = 0x0200_0000
        var f = registerWorkq(t, [KEventRecord(ident: 1, filter: -10, flags: 0x21, qos: mgr)])
        #expect(!f.carry && f.x[0] == 0 && t.host.starts.isEmpty)
        // NOTE_TRIGGER: a manager upcall with the event.
        f = registerWorkq(t, [KEventRecord(ident: 1, filter: -10, flags: 0, fflags: 0x0100_0000, qos: mgr)])
        #expect(!f.carry)
        let s = try #require(t.host.starts.first)
        let me = s.state.x[0], list = me - 1152
        #expect(s.state.x[4] == Self.newSPI | Self.kevent | Self.manager | Self.prioQoS | 8 | Self.tsdSet)
        #expect(s.state.x[3] == list && s.state.x[5] == 1 && s.state.sp == list)
        let e = events(t, at: list, count: 1)[0]
        #expect(e.ident == 1 && e.filter == -10 && e.flags & 0x4000 == 0)
        // Triggered again while delivered: no second manager; redelivered at return.
        registerWorkq(t, [KEventRecord(ident: 1, filter: -10, fflags: 0x0100_0000, qos: mgr)])
        #expect(t.host.starts.count == 1)
        let (o, r) = t.svc(368, [0x40, 0, 0, 0], context: s.context)
        #expect(o == .resume && r.x[5] == 1 && r.x[4] == Self.newSPI | Self.kevent | Self.manager | Self.prioQoS | 8 | Self.reuse)
        // Nothing more: it parks.
        let parked = workerReturn(t, s.context, op: 0x40)
        #expect(t.eventually { t.kernel.idleWorkqueueThreads.count == 1 })
        t.kernel.shutdown()
        _ = parked()
    }

    /// No free vCPU: the event is not delivered to a thread that cannot run
    /// (an EV_DISPATCH knote would stay disabled forever); the request waits
    /// and starts when a vCPU becomes free (launchd_sim stalled at its
    /// 64-vCPU limit in stage 7 runs).
    @Test func noFreeVCPUKeepsTheEventForLater() throws {
        let t = try T2Env()
        open(t)
        t.host.limit = 0
        let mgr: UInt32 = 0x0200_0000
        // EV_ADD | EV_CLEAR | EV_DISPATCH, then NOTE_TRIGGER.
        registerWorkq(t, [KEventRecord(ident: 1, filter: -10, flags: 0x1 | 0x20 | 0x80, qos: mgr)])
        registerWorkq(t, [KEventRecord(ident: 1, filter: -10, fflags: 0x0100_0000, qos: mgr)])
        #expect(t.host.starts.isEmpty)
        t.host.limit = Int.max
        t.kernel.retryPendingWorkqueue()
        let s = try #require(t.host.starts.first)
        #expect(s.state.x[5] == 1)
        let e = events(t, at: s.state.x[3], count: 1)[0]
        #expect(e.ident == 1 && e.filter == -10)
        t.kernel.shutdown()
    }

    /// A bucket handed to an idle worker is bound to it at once: an
    /// activation before that worker runs must not start a second one
    /// (stage 4c-iii: two launchd_sim threads serviced one workloop, and the
    /// first to return left the other unbound → EXDEV).
    @Test func assignedBucketIsBoundBeforeTheWorkerRuns() throws {
        let t = try T2Env()
        open(t)
        t.svc(368, [0x20, 0, 1, UInt64(Self.legacy)])
        let ctx = t.host.starts[0].context
        let parked = workerReturn(t, ctx)
        #expect(t.eventually { t.kernel.idleWorkqueueThreads.contains { $0 === ctx } })
        registerWorkq(t, [KEventRecord(ident: 1, filter: -10, flags: 0x21, qos: Self.legacy)])
        // Holding the (re-entrant) kernel lock keeps the woken worker from
        // running its upcall while the event fires twice.
        t.kernel.lock.withLock {
            registerWorkq(t, [KEventRecord(ident: 1, filter: -10, fflags: 0x0100_0000, qos: Self.legacy)])
            // Handed to the idle worker (no new thread), and bound to it.
            #expect(t.host.starts.count == 1)
            #expect(t.kernel.kevents.workq!.buckets[4]?.boundWorker === ctx)
            // Triggered again: still one thread, no second request.
            registerWorkq(t, [KEventRecord(ident: 1, filter: -10, fflags: 0x0100_0000, qos: Self.legacy)])
            #expect(t.host.starts.count == 1)
            #expect(t.kernel.kevents.workq!.buckets[4]?.requested != true)
        }
        let (o, f) = try #require(parked())
        #expect(o == .resume && f.x[4] & Self.kevent != 0 && f.x[5] >= 1)
    }

    @Test func timerFiresIntoAKeventUpcall() throws {
        let t = try T2Env()
        open(t)
        // One-shot relative 20 ms timer at legacy QoS.
        registerWorkq(t, [KEventRecord(ident: 5, filter: -7, flags: 0x11, fflags: 0x4, data: 20_000_000, qos: Self.legacy)])
        #expect(t.host.starts.isEmpty)
        #expect(t.eventually { t.host.starts.count == 1 })
        let s = t.host.starts[0]
        #expect(s.state.x[4] == Self.newSPI | Self.kevent | Self.overcommit | Self.prioQoS | 4 | Self.tsdSet)
        let e = events(t, at: s.state.x[3], count: 1)[0]
        #expect(e.ident == 5 && e.filter == -7 && e.data == 1)
        // Oneshot: gone after delivery.
        #expect(t.kernel.lock.withLock { t.kernel.kevents.workq!.knotes.isEmpty })
        // An absolute mach-time timer in the past fires at once.
        let past = MachTimebase.now() - 10
        registerWorkq(t, [KEventRecord(ident: 6, filter: -7, flags: 0x11, fflags: 0x108, data: Int64(past), qos: 0x10FF)])
        #expect(t.eventually { t.host.starts.count == 2 })
    }

    @Test func changeErrorsAndReceipts() throws {
        let t = try T2Env()
        open(t)
        let c = Env.scratch + 0x2000, o = Env.scratch + 0x3000
        // Asking the workqueue kqueue for events: EINVAL.
        put(t, [], at: c)
        #expect(t.svc(374, [UInt64.max, c, 0, o, 1, 0, 0, Self.workq]).1.x[0] == 22)
        // MEMORYSTATUS: an EV_ERROR event (ENOTSUP); unknown filter: EINVAL; receipt: data 0.
        let f = registerWorkq(t, [KEventRecord(ident: 0, filter: -14, flags: 1, qos: Self.legacy),
                                  KEventRecord(ident: 0, filter: -40, flags: 1),
                                  KEventRecord(ident: 9, filter: -10, flags: 0x41, qos: Self.legacy),
                                  KEventRecord(ident: 77, filter: -10, flags: 2)], out: 4)
        #expect(!f.carry && f.x[0] == 4)
        let out = events(t, at: o, count: 4)
        #expect(out.map(\.flags).allSatisfy { $0 & 0x4000 != 0 })
        #expect(out.map(\.data) == [45, 22, 0, 2])
        // No room for an error: the call fails.
        let g = registerWorkq(t, [KEventRecord(ident: 0, filter: -14, flags: 1, qos: Self.legacy)])
        #expect(g.carry && g.x[0] == 45)
        // kevent_id rules.
        #expect(t.svc(375, [0, c, 0, o, 0, 0, 0, Self.wlFlag]).1.x[0] == 22)
        #expect(t.svc(375, [0x1234, c, 0, o, 0, 0, 0, Self.wlFlag | 0x20000]).1.x[0] == 2)  // MUST_EXIST
        #expect(t.svc(375, [0x1234, c, 0, o, 1, 0, 0, Self.wlFlag]).1.x[0] == 18)  // not the servicer: EXDEV
        // EVFILT_WORKLOOP outside a workloop.
        let h = registerWorkq(t, [KEventRecord(ident: 1, filter: -17, flags: 1, qos: Self.legacy)], out: 1)
        #expect(h.x[0] == 1 && events(t, at: o, count: 1)[0].data == 45)
    }

    // MARK: Workloops

    func workloopCall(_ t: T2Env, _ id: UInt64, _ changes: [KEventRecord], out: Int = 1, flags: UInt64 = 0,
                      context: ThreadContext? = nil) -> TrapFrame {
        let c = Env.scratch + 0x4000, o = Env.scratch + 0x5000
        if context == nil { put(t, changes, at: c) }
        return t.svc(375, [id, c, UInt64(changes.count), o, UInt64(out), 0, 0,
                           Self.wlFlag | Self.errorEvents | flags], context: context).1
    }

    func threadRequest(_ id: UInt64, cmd: UInt32 = 0x1 | 0x100 | 0x10, state: UInt64 = 0, mask: UInt64 = 0,
                       value: UInt64 = 0) -> KEventRecord {
        KEventRecord(ident: id, filter: -17, flags: 0x5, fflags: cmd, qos: 0x8000_10FF, ext: [0, state, mask, value])
    }

    @Test func workloopThreadRequestUpcall() throws {
        let t = try T2Env()
        open(t)
        let id: UInt64 = 0x7000_1000
        let state = Env.scratch + 0x900
        t.put64(0x55, at: state)
        // Debounce mismatch: ESTALE, the loaded value in ext[3].
        var f = workloopCall(t, id, [threadRequest(id, cmd: 0x11, state: state, mask: ~0, value: 0x44)], flags: Self.immediate)
        #expect(f.x[0] == 1)
        var e = events(t, at: Env.scratch + 0x5000, count: 1)[0]
        #expect(e.data == 70 && e.ext[3] == 0x55)
        #expect(t.host.starts.isEmpty)
        // With IGNORE_ESTALE: silently not applied.
        f = workloopCall(t, id, [threadRequest(id, state: state, mask: ~0, value: 0x44)], flags: Self.immediate)
        #expect(f.x[0] == 0 && t.host.starts.isEmpty)
        // Matching: a workloop upcall.
        f = workloopCall(t, id, [threadRequest(id, state: state, mask: ~0, value: 0x55)], flags: Self.immediate)
        #expect(!f.carry && f.x[0] == 0)
        let s = try #require(t.host.starts.first)
        let list = s.state.x[3]
        #expect(s.state.x[4] == Self.newSPI | Self.kevent | Self.workloop | Self.overcommit | Self.prioQoS | 5 | Self.tsdSet)
        #expect(s.state.x[5] == 1 && t.u64(list - 8) == id && s.state.sp == (list - 8) & ~15)
        e = events(t, at: list, count: 1)[0]
        #expect(e.filter == -17 && e.ident == id && e.fflags == 0x111 && e.data == 0)
        // Only the servicer may poll it.
        let c = Env.scratch + 0x4000, o = Env.scratch + 0x5000
        #expect(t.svc(375, [id, c, 0, o, 4, 0, 0, Self.wlFlag | Self.immediate]).1.x[0] == 18)
        let (_, poll) = t.svc(375, [id, c, 0, o, 4, 0, 0, Self.wlFlag | Self.immediate | 0x20000], context: s.context)
        #expect(!poll.carry && poll.x[0] == 0)  // delivered knote is suppressed
        // Return: the thread request is EV_CLEAR, so nothing is left; it parks.
        let parked = workerReturn(t, s.context, op: 0x100)
        #expect(t.eventually { t.kernel.idleWorkqueueThreads.count == 1 })
        #expect(t.kernel.lock.withLock { t.kernel.kevents.workloops[id]?.servicer == nil })
        // Re-arm: the idle worker takes it.
        f = workloopCall(t, id, [threadRequest(id, state: state, mask: ~0, value: 0x55)], flags: Self.immediate)
        let (o2, r) = try #require(parked())
        #expect(o2 == .resume && r.x[4] & (Self.workloop | Self.reuse) == Self.workloop | Self.reuse)
        #expect(t.host.starts.count == 1)
    }

    @Test func workloopOwnerHoldsTheRequest() throws {
        let t = try T2Env()
        open(t)
        let id: UInt64 = 0x7000_2000
        let state = Env.scratch + 0xA00
        t.put64(0x203, at: state)  // the main thread drains the queue
        let f = workloopCall(t, id, [threadRequest(id, cmd: 0x1 | 0x10 | 0x80, state: state, mask: 0, value: 0)],
                             flags: Self.immediate)
        #expect(f.x[0] == 0)
        #expect(t.host.starts.isEmpty)  // owner set: not delivered
        #expect(t.kernel.lock.withLock { t.kernel.kevents.workloops[id]?.owner === t.main })
        // A dead owner name: EOWNERDEAD.
        t.put64(0x9993, at: state)
        let g = workloopCall(t, id, [threadRequest(id, cmd: 0x1 | 0x10 | 0x80, state: state, mask: 0, value: 0)],
                             flags: Self.immediate)
        #expect(g.x[0] == 1 && events(t, at: Env.scratch + 0x5000, count: 1)[0].data == 105)
        // The owner ends ownership: the request goes out.
        let h = workloopCall(t, id, [KEventRecord(ident: id, filter: -17, flags: 0x5, fflags: 0x1 | 0x20, qos: 0x8FF)],
                             flags: Self.immediate)
        #expect(h.x[0] == 0)
        #expect(t.eventually { t.host.starts.count == 1 })
    }

    @Test func workloopSyncWaitAndWake() throws {
        let t = try T2Env()
        open(t)
        let id: UInt64 = 0x7000_3000
        let (a, _) = t.createThread()
        let state = Env.scratch + 0xB00
        // SYNC_WAIT must be added disabled.
        let bad = workloopCall(t, id, [KEventRecord(ident: 99, filter: -17, flags: 0x1, fflags: 0x4, qos: 0x8FF)])
        #expect(bad.x[0] == 1 && events(t, at: Env.scratch + 0x5000, count: 1)[0].data == 22)
        // a waits (blocks inside kevent_id).
        let wc = Env.scratch + 0x6000, wo = Env.scratch + 0x6100
        put(t, [KEventRecord(ident: a.threadID, filter: -17, flags: 0x9, fflags: 0x4, qos: 0x8FF)], at: wc)
        let wait = t.spawn {
            t.svc(375, [id, wc, 1, wo, 1, 0, 0, Self.wlFlag | Self.errorEvents], context: a).1.x[0]
        }
        #expect(t.eventually { t.blocked(a) })
        // Wake it and hand it ownership.
        t.put64(UInt64(a.portName), at: state)
        let f = workloopCall(t, id, [KEventRecord(ident: a.threadID, filter: -17, flags: 0x9, fflags: 0x8 | 0x80, qos: 0x8FF,
                                                  ext: [0, state, 0, 0])])
        #expect(f.x[0] == 0)
        #expect(wait() == 0)
        #expect(t.kernel.lock.withLock { t.kernel.kevents.workloops[id]?.owner === a })
        // Waking twice succeeds (xnu filt_wlupdate: no EALREADY for SYNC_WAKE).
        let twice = workloopCall(t, id, [KEventRecord(ident: a.threadID, filter: -17, flags: 0x9, fflags: 0x8, qos: 0x8FF)])
        #expect(twice.x[0] == 0)
        // Sync end from a: delete + end ownership.
        put(t, [KEventRecord(ident: a.threadID, filter: -17, flags: 0x6, fflags: 0x8 | 0x20, qos: 0x8FF)], at: wc)
        let (_, end) = t.svc(375, [id, wc, 1, wo, 1, 0, 0, Self.wlFlag | Self.errorEvents], context: a)
        #expect(end.x[0] == 0)
        #expect(t.kernel.lock.withLock { t.kernel.kevents.workloops[id] == nil })  // freed: nothing refers to it
        // Deleting an un-woken waiter wakes it.
        put(t, [KEventRecord(ident: a.threadID, filter: -17, flags: 0x9, fflags: 0x4, qos: 0x8FF)], at: wc)
        let wait2 = t.spawn {
            t.svc(375, [id, wc, 1, wo, 1, 0, 0, Self.wlFlag | Self.errorEvents], context: a).1.x[0]
        }
        #expect(t.eventually { t.blocked(a) })
        let del = workloopCall(t, id, [KEventRecord(ident: a.threadID, filter: -17, flags: 0x2, fflags: 0x8, qos: 0x8FF)])
        #expect(del.x[0] == 0)
        #expect(wait2() == 0)
    }

    @Test func workloopCtl() throws {
        let t = try T2Env()
        var p = [UInt8](repeating: 0, count: 36)
        p.putLE(Int32(36), at: 0)
        p.putLE(Int32(1), at: 4)
        p.putLE(UInt64(0x7000_4000), at: 8)
        p.putLE(Int32(47), at: 16)
        t.put(p, at: Env.scratch + 0xC00)
        #expect(t.x0(530, [1, 0, Env.scratch + 0xC00, 36]) == 0)
        #expect(t.x0(530, [1, 0, Env.scratch + 0xC00, 36]) == 17)
        #expect(t.kernel.lock.withLock { t.kernel.kevents.workloops[0x7000_4000]?.fixedPriority } == true)
        #expect(t.x0(530, [2, 0, Env.scratch + 0xC00, 36]) == 0)
        #expect(t.kernel.lock.withLock { t.kernel.kevents.workloops[0x7000_4000] } == nil)
        #expect(t.x0(530, [2, 0, Env.scratch + 0xC00, 36]) == 2)
        p.putLE(Int32(0), at: 4)
        t.put(p, at: Env.scratch + 0xC00)
        #expect(t.x0(530, [1, 0, Env.scratch + 0xC00, 36]) == 22)
        #expect(t.x0(530, [3, 0, Env.scratch + 0xC00, 36]) == 22)
    }

    // MARK: Descriptor kqueues

    func kevent64(_ t: T2Env, _ changes: [KEventRecord], out: Int, timeoutNs: UInt64?, context: ThreadContext? = nil)
        -> TrapFrame {
        let c = Env.scratch + 0x7000, o = Env.scratch + 0x7800, ts = Env.scratch + 0x7F00
        if context == nil {
            put(t, changes, at: c, format: .k64)
            if let timeoutNs { t.put(leBytes(timeoutNs / 1_000_000_000) + leBytes(timeoutNs % 1_000_000_000), at: ts) }
        }
        return t.svc(369, [9, c, UInt64(changes.count), o, UInt64(out), 0, timeoutNs == nil ? 0 : ts], context: context).1
    }

    @Test func descriptorKQueueWaitsAndFlagSemantics() throws {
        let t = try T2Env()
        t.kernel.lock.withLock { t.kernel.installDescriptorKQueue(9) }
        // Add without trigger; a 10 ms scan returns nothing.
        var f = kevent64(t, [KEventRecord(ident: 1, filter: -10, flags: 0x1)], out: 4, timeoutNs: 10_000_000)
        #expect(!f.carry && f.x[0] == 0)
        // A blocked scanner wakes when another thread triggers.
        let (a, _) = t.createThread()
        let c = Env.scratch + 0x7000, o = Env.scratch + 0x7800
        let scan = t.spawn { t.svc(369, [9, c, 0, o, 4, 0, 0], context: a).1.x[0] }
        #expect(t.eventually { t.blocked(a) })
        f = kevent64(t, [KEventRecord(ident: 1, filter: -10, flags: 0, fflags: 0x0100_0000 | 0xC000_0005, data: 3)],
                     out: 0, timeoutNs: 0)
        #expect(scan() == 1)
        let e = events(t, at: o, count: 1, format: .k64)[0]
        #expect(e.ident == 1 && e.fflags == 5 && e.data == 3)
        // Level-triggered: reported again.
        #expect(kevent64(t, [], out: 4, timeoutNs: 0).x[0] == 1)
        // EV_DISPATCH: disabled after one delivery; EV_ENABLE re-arms.
        kevent64(t, [KEventRecord(ident: 2, filter: -10, flags: 0x81, fflags: 0x0100_0000)], out: 0, timeoutNs: 0)
        kevent64(t, [KEventRecord(ident: 1, filter: -10, flags: 0x2)], out: 0, timeoutNs: 0)
        #expect(kevent64(t, [], out: 4, timeoutNs: 0).x[0] == 1)
        #expect(kevent64(t, [], out: 4, timeoutNs: 0).x[0] == 0)
        kevent64(t, [KEventRecord(ident: 2, filter: -10, flags: 0x4)], out: 0, timeoutNs: 0)
        #expect(kevent64(t, [], out: 4, timeoutNs: 0).x[0] == 1)
        // EV_DISPATCH2 deferred delete: EINPROGRESS, then a synthetic delete on enable.
        kevent64(t, [KEventRecord(ident: 2, filter: -10, flags: 0x2)], out: 0, timeoutNs: 0)
        kevent64(t, [KEventRecord(ident: 3, filter: -10, flags: 0x181, fflags: 0x0100_0000, udata: 0xAB)], out: 0, timeoutNs: 0)
        #expect(kevent64(t, [], out: 4, timeoutNs: 0).x[0] == 1)
        f = kevent64(t, [KEventRecord(ident: 3, filter: -10, flags: 0x102, udata: 0xAB)], out: 1, timeoutNs: 0)
        #expect(f.x[0] == 1 && events(t, at: o, count: 1, format: .k64)[0].data == 36)
        f = kevent64(t, [KEventRecord(ident: 3, filter: -10, flags: 0x104, udata: 0xAB)], out: 4, timeoutNs: 0)
        #expect(f.x[0] == 1)
        let synthetic = events(t, at: o, count: 1, format: .k64)[0]
        #expect(synthetic.flags & 0x192 == 0x192)  // DELETE | DISPATCH2 | ONESHOT
        #expect(t.kernel.lock.withLock { t.kernel.kevents.descriptorQueues[9]!.knotes.isEmpty })
        // A repeating 2 ms timer reports expirations.
        kevent64(t, [KEventRecord(ident: 4, filter: -7, flags: 0x1, fflags: 0x2, data: 2000)], out: 0, timeoutNs: 0)
        Thread.sleep(forTimeInterval: 0.02)
        f = kevent64(t, [], out: 4, timeoutNs: 1_000_000_000)
        #expect(f.x[0] == 1 && events(t, at: o, count: 1, format: .k64)[0].data >= 1)
        // Timer unit errors.
        f = kevent64(t, [KEventRecord(ident: 5, filter: -7, flags: 0x1, fflags: 0x3, data: 1)], out: 1, timeoutNs: 0)
        #expect(events(t, at: o, count: 1, format: .k64)[0].data == 22)
        // Mixing kevent and kevent64 on one kqueue: EINVAL.
        #expect(t.svc(363, [9, c, 0, o, 0, 0]).1.x[0] == 22)
        #expect(t.svc(363, [10, c, 0, o, 0, 0]).1.x[0] == 9)
    }

    /// EV_VANISHED at EV_ADD is a request (xnu `KN_REQVANISH`): ordinary
    /// EVFILT_MACHPORT events do not carry it (libdispatch crashes on an
    /// EV_VANISHED message event); only the end-of-life event does.
    @Test func machPortVanishIsARequestNotAFlag() throws {
        let t = try T2Env()
        let out = Env.scratch + 0x5000, c = Env.scratch + 0x2000, o = Env.scratch + 0x3000, msg = Env.scratch + 0x4000
        func allocate() -> UInt64 {
            #expect(t.x0(UInt64(bitPattern: -16), [0x103, 1, out]) == 0)
            return UInt64(t.read(out, 4).readLE(UInt32.self, at: 0))
        }
        let a = allocate(), b = allocate()
        let kq = t.x0(362)
        // EV_ADD | EV_DISPATCH | EV_UDATA_SPECIFIC | EV_VANISHED, fflags 0 (no receive).
        put(t, [KEventRecord(ident: a, filter: -8, flags: 0x381, udata: 0xA),
                KEventRecord(ident: b, filter: -8, flags: 0x381, udata: 0xB)], at: c)
        #expect(t.x0(374, [kq, c, 2, o, 0, 0, 0, Self.immediate | Self.errorEvents]) == 0)
        // A message on a: the event has no EV_VANISHED.
        #expect(t.x0(UInt64(bitPattern: -21), [0x103, a, a, 20]) == 0)  // MAKE_SEND
        var header = [UInt8](repeating: 0, count: 24)
        header.putLE(UInt32(19), at: 0)  // COPY_SEND
        header.putLE(UInt32(24), at: 4)
        header.putLE(UInt32(a), at: 8)
        header.putLE(UInt32(0x42), at: 20)
        t.put(header, at: msg)
        #expect(t.x0(UInt64(bitPattern: -31), [msg, 1, 24, 0, 0, 0, 0]) == 0)
        #expect(t.x0(374, [kq, c, 0, o, 4, 0, 0, Self.immediate]) == 1)
        let e = events(t, at: o, count: 1)[0]
        #expect(e.ident == a && e.udata == 0xA && e.flags & 0x200 == 0 && e.flags & 0x8000 == 0)
        // b's receive right is destroyed: its event is EV_VANISHED.
        #expect(t.x0(UInt64(bitPattern: -19), [0x103, b, 1, 0xFFFF_FFFF]) == 0)
        #expect(t.x0(374, [kq, c, 0, o, 4, 0, 0, Self.immediate]) == 1)
        let v = events(t, at: o, count: 1)[0]
        #expect(v.ident == b && v.udata == 0xB && v.flags & 0x200 != 0)
    }
}
