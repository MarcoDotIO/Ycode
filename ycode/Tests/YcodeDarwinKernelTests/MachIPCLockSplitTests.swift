import Foundation
import Synchronization
import Testing
import YcodeDarwinABI
@testable import YcodeDarwinKernel

/// Several images of one system with the IPC lock split on
/// (`specs/simulator/mach-ipc-locking.md` §4), many host threads each acting
/// as one guest thread, and traps sent through the fast path or the locked
/// path (as the VMM does: the fast path first, the locked path when it
/// declines).
final class SplitWorld: @unchecked Sendable {
    static let scratch: UInt64 = 0x1_0000_0000
    static let scratchSize: UInt64 = 0x40000
    static let out: UInt64 = scratch + 0x3F000

    let system = DarwinSystem(ipcLocks: true)
    var tasks: [TaskWorld.Task] = []
    private var nextThreadID: UInt64 = 10
    /// Traps that took the fast path, and all traps.
    let fastCount = Atomic<Int>(0)
    let trapCount = Atomic<Int>(0)

    init() {
        KernelThreadLocks.checkOrder = true
    }

    @discardableResult
    func add(pid: Int32) throws -> TaskWorld.Task {
        let fs = DarwinFileSystem(prefixes: [], console: { _, _ in })
        let kernel = DarwinKernel(fileSystem: fs, pid: pid, system: system)
        kernel.tracing = false  // as in the VMM: the fast paths decline traced images
        let space = GuestAddressSpace(backing: FakePhysicalBacking())
        _ = try space.mapAnonymous(at: Self.scratch, size: Self.scratchSize, protection: .readWrite, hint: nil)
        let t = TaskWorld.Task(kernel: kernel, ipc: kernel.machIPC as! MachIPC, space: space)
        tasks.append(t)
        return t
    }

    /// A guest thread of `t` (its own thread port).
    func thread(_ t: TaskWorld.Task) -> ThreadContext {
        let id = system.lock.withLock { () -> UInt64 in
            nextThreadID += 1
            return nextThreadID
        }
        let ctx = ThreadContext(threadID: id, portName: t.ipc.allocateThreadPort(), vcpuIndex: Int(id % 64), kind: .pthread)
        ctx.kernel = t.kernel
        return ctx
    }

    /// One trap: the fast path when `fast` and it accepts, else the locked path.
    @discardableResult
    func trap(_ t: TaskWorld.Task, _ ctx: ThreadContext, _ n: Int64, _ args: [UInt64], fast: Bool) -> UInt64 {
        var f = TrapFrame()
        f.kind = TrapFrame.Kind.svc.rawValue
        f.x[16] = UInt64(bitPattern: n)
        for (i, v) in args.enumerated() { f.x[i] = v }
        trapCount.wrappingAdd(1, ordering: .relaxed)
        if fast, t.kernel.handleIPCFast(&f, context: ctx, memory: t.space) != nil {
            fastCount.wrappingAdd(1, ordering: .relaxed)
            return f.x[0]
        }
        _ = t.kernel.handle(&f, context: ctx, memory: t.space)
        return f.x[0]
    }

    func kr(_ t: TaskWorld.Task, _ ctx: ThreadContext, _ n: Int64, _ args: [UInt64], fast: Bool = false) -> UInt32 {
        UInt32(truncatingIfNeeded: trap(t, ctx, n, args, fast: fast))
    }

    // Guest memory is written and read under L0 (no fast path runs then).
    func put(_ t: TaskWorld.Task, _ bytes: [UInt8], at va: UInt64) { system.lock.withLock { try! t.space.write(va: va, bytes: bytes) } }
    func read(_ t: TaskWorld.Task, _ va: UInt64, _ count: Int) -> [UInt8] {
        system.lock.withLock { try! t.space.read(va: va, count: count) }
    }

    func allocate(_ t: TaskWorld.Task, _ right: UInt32 = MachPortRight.receive) -> UInt32 {
        let ctx = t.kernel.mainThread
        precondition(kr(t, ctx, -16, [0x103, UInt64(right), Self.out]) == 0)
        return read(t, Self.out, 4).readLE(UInt32.self, at: 0)
    }

    func give(_ name: UInt32, from: TaskWorld.Task, to: TaskWorld.Task, disposition: UInt32) -> UInt32 {
        system.lock.withLock {
            guard case let .success(r) = from.ipc.copyin(name, disposition, slot: .body, apply: true) else {
                preconditionFailure("copyin failed")
            }
            return to.ipc.copyout(r).name
        }
    }

    /// `mach_msg_trap`: send `msg` from `buffer` (and receive on `rcvName`
    /// into the same buffer when it is not 0).
    func machMsg(_ t: TaskWorld.Task, _ ctx: ThreadContext, _ msg: [UInt8]?, at buffer: UInt64, rcvName: UInt32 = 0,
                 rcvTimeoutMs: UInt32? = nil, sendTimeoutMs: UInt32? = nil, fast: Bool) -> (UInt32, Received) {
        var options: UInt64 = 0
        if let msg {
            put(t, msg, at: buffer)
            options |= MachMsgOption.sendMsg
        }
        if rcvName != 0 { options |= MachMsgOption.rcvMsg }
        if rcvTimeoutMs != nil { options |= MachMsgOption.rcvTimeout }
        if sendTimeoutMs != nil { options |= MachMsgOption.sendTimeout }
        let timeout = UInt64(rcvTimeoutMs ?? sendTimeoutMs ?? 0)
        let k = kr(t, ctx, -31, [buffer, options, UInt64(msg?.count ?? 0), rcvName != 0 ? 0x200 : 0, UInt64(rcvName),
                                 timeout, 0], fast: fast)
        let r = rcvName != 0 && k == 0 ? Received(read(t, buffer, 0x200)) : Received([UInt8](repeating: 0, count: 64))
        return (k, r)
    }

    /// `mach_msg2_trap`, send only, a simple message with `inline` body.
    func machMsg2Send(_ t: TaskWorld.Task, _ ctx: ThreadContext, remote: UInt32, disposition: UInt32, id: Int32,
                      inline: [UInt8], at buffer: UInt64, fast: Bool) -> UInt32 {
        put(t, [UInt8](repeating: 0, count: 24) + inline, at: buffer)
        let bits = MachMsgBits.make(remote: disposition, local: 0)
        let size = UInt64(24 + inline.count)
        return kr(t, ctx, -47, [buffer, MachMsgOption.sendMsg | MachMsgOption.sendMQCall, UInt64(bits) | size << 32,
                                UInt64(remote), UInt64(UInt32(bitPattern: id)) << 32, 0, 0, 0], fast: fast)
    }

    func counters(_ t: TaskWorld.Task, _ name: UInt32) -> (srights: Int, sorights: Int, msgcount: Int, active: Bool)? {
        t.ipc.portCounters(name).map { ($0.srights, $0.sorights, $0.msgcount, $0.active) }
    }
}

/// Runs `body` on its own thread; the returned function waits for it (at
/// most `seconds`, nil when it did not finish).
func spawnThread<T: Sendable>(seconds: Double = 60, _ body: @escaping @Sendable () -> T) -> () -> T? {
    let done = DispatchSemaphore(value: 0)
    let box = ResultBox<T>()
    let thread = Thread {
        box.value = body()
        done.signal()
    }
    thread.stackSize = 1 << 20
    thread.start()
    return { done.wait(timeout: .now() + seconds) == .success ? box.value : nil }
}

@Suite struct MachIPCLockSplitTests {
    /// Clients in several images call servers in other images (send with a
    /// make-send-once reply port, receive the reply in the same trap), the
    /// servers' threads answer; every trap picks the fast or the locked path.
    @Test func requestReplyStormAcrossImages() throws {
        let w = SplitWorld()
        let servers = try (0..<3).map { try w.add(pid: 200 + Int32($0)) }
        let clients = try (0..<4).map { try w.add(pid: 300 + Int32($0)) }
        let service = servers.map { w.allocate($0) }
        let names = clients.map { c in servers.indices.map { i in w.give(service[i], from: servers[i], to: c, disposition: MachMsgType.makeSend) } }
        let threadsPerClient = 3, rounds = 150, serverThreads = 2
        let total = clients.count * threadsPerClient * rounds
        let served = Atomic<Int>(0)

        var waits: [() -> Int?] = []
        for (si, s) in servers.enumerated() {
            for k in 0..<serverThreads {
                let ctx = w.thread(s)
                let buffer = SplitWorld.scratch + 0x1000 * UInt64(k + 1)
                waits.append(spawnThread {
                    var n = 0, turn = k
                    while served.load(ordering: .relaxed) < total {
                        turn += 1
                        let (code, r) = w.machMsg(s, ctx, nil, at: buffer, rcvName: service[si], rcvTimeoutMs: 20,
                                                  fast: turn % 3 != 0)
                        if code == MachMsgReturn.rcvTimedOut { continue }
                        guard code == 0 else { return -1 }
                        let answer = TestMessage(remote: r.remote, remoteDisposition: MachMsgType.moveSendOnce,
                                                 id: r.id + 1, inline: Array(r.raw[24..<28]))
                        let (sent, _) = w.machMsg(s, ctx, answer.bytes, at: buffer, fast: turn % 4 != 0)
                        guard sent == 0 else { return -2 }
                        n += 1
                        served.wrappingAdd(1, ordering: .relaxed)
                    }
                    return n
                })
            }
        }
        var clientWaits: [() -> Int?] = []
        for (ci, c) in clients.enumerated() {
            for j in 0..<threadsPerClient {
                let ctx = w.thread(c)
                let reply = w.allocate(c)
                let buffer = SplitWorld.scratch + 0x10000 + 0x1000 * UInt64(j)
                clientWaits.append(spawnThread {
                    var ok = 0
                    for r in 0..<rounds {
                        let si = (r + j + ci) % servers.count
                        let id = Int32(ci * 100_000 + j * 10_000 + r * 2)
                        let tag = UInt32(ci * 1000 + j)
                        let m = TestMessage(remote: names[ci][si], remoteDisposition: MachMsgType.copySend, local: reply,
                                            localDisposition: MachMsgType.makeSendOnce, id: id, inline: le32(tag))
                        let (code, got) = w.machMsg(c, ctx, m.bytes, at: buffer, rcvName: reply, rcvTimeoutMs: 20_000,
                                                    fast: (r + j) % 5 != 0)
                        if code == 0, got.id == id + 1, got.u32(24) == tag, got.local == reply { ok += 1 }
                    }
                    return ok
                })
            }
        }
        for c in clientWaits { #expect(c() == rounds) }
        let perServer = waits.map { $0() }
        #expect(perServer.allSatisfy { ($0 ?? -1) >= 0 })
        #expect(perServer.reduce(0) { $0 + ($1 ?? 0) } == total)
        #expect(w.fastCount.load(ordering: .relaxed) > w.trapCount.load(ordering: .relaxed) / 3)
        // Rights balance: one send-right entry per client, no message left.
        for (i, s) in servers.enumerated() {
            let c = w.counters(s, service[i])
            #expect(c?.srights == clients.count && c?.msgcount == 0 && c?.sorights == 0)
        }
    }

    /// A server learns of messages through an EVFILT_MACHPORT knote of a
    /// descriptor kqueue (its thread sleeps in `kevent64` on the event lock);
    /// clients send on the fast path and then block for the answer, so the
    /// knote hook (deferred to the server image's event lock) must run
    /// before the client sleeps.
    @Test func kqueueHookWakesTheServerBeforeTheClientSleeps() throws {
        let w = SplitWorld()
        let server = try w.add(pid: 200)
        let clients = try (0..<3).map { try w.add(pid: 300 + Int32($0)) }
        let port = w.allocate(server)
        let names = clients.map { w.give(port, from: server, to: $0, disposition: MachMsgType.makeSend) }
        w.system.lock.withLock { server.kernel.installDescriptorKQueue(9) }
        let sctx = w.thread(server)
        let change = KEventRecord(ident: UInt64(port), filter: EVFilter.machport, flags: 0x1, fflags: 0, data: 0,
                                  udata: 0, qos: 0, ext: [0, 0, 0, 0]).encoded(.k64)
        let c = SplitWorld.scratch + 0x7000, o = SplitWorld.scratch + 0x7800, ts = SplitWorld.scratch + 0x7F00
        w.put(server, change, at: c)
        #expect(w.trap(server, sctx, 369, [9, c, 1, o, 0, 0, 0], fast: false) == 0)
        w.put(server, le64(2) + le64(0), at: ts)
        let rounds = 80
        let total = clients.count * rounds
        let serverDone = spawnThread { () -> Int in
            var n = 0, idle = 0
            while n < total && idle < 10 {
                // Wait for the knote (2 s at most), then drain the port on the fast path.
                let events = w.trap(server, sctx, 369, [9, c, 0, o, 1, 0, ts], fast: false)
                if events == 0 { idle += 1; continue }
                idle = 0
                while true {
                    let (code, r) = w.machMsg(server, sctx, nil, at: SplitWorld.scratch + 0x1000, rcvName: port,
                                              rcvTimeoutMs: 0, fast: true)
                    if code != 0 { break }
                    let answer = TestMessage(remote: r.remote, remoteDisposition: MachMsgType.moveSendOnce, id: r.id + 1)
                    _ = w.machMsg(server, sctx, answer.bytes, at: SplitWorld.scratch + 0x1000, fast: n % 2 == 0)
                    n += 1
                }
            }
            return n
        }
        var waits: [() -> Int?] = []
        for (ci, cl) in clients.enumerated() {
            let ctx = w.thread(cl)
            let reply = w.allocate(cl)
            waits.append(spawnThread {
                var ok = 0
                for r in 0..<rounds {
                    let id = Int32(ci * 10_000 + r * 2)
                    let m = TestMessage(remote: names[ci], remoteDisposition: MachMsgType.copySend, local: reply,
                                        localDisposition: MachMsgType.makeSendOnce, id: id)
                    let (code, got) = w.machMsg(cl, ctx, m.bytes, at: SplitWorld.scratch + 0x2000, rcvName: reply,
                                                rcvTimeoutMs: 10_000, fast: true)
                    if code == 0, got.id == id + 1 { ok += 1 }
                }
                return ok
            })
        }
        for wt in waits { #expect(wt() == rounds) }
        #expect(serverDone() == total)
        #expect(w.fastCount.load(ordering: .relaxed) >= total)
    }

    /// A one-message queue: senders on the fast path block in the full
    /// queue (port lock waits); a receiver drains it on both paths. Every
    /// message arrives once and each sender's messages in order.
    @Test func fullQueueBlocksSendersAndKeepsOrder() throws {
        let w = SplitWorld()
        let rx = try w.add(pid: 200)
        let port = w.allocate(rx)
        #expect(w.system.lock.withLock { rx.ipc.portSetAttributes(port, flavor: 1, info: [1]) } == 0)
        let senders = try (0..<4).map { try w.add(pid: 300 + Int32($0)) }
        let names = senders.map { w.give(port, from: rx, to: $0, disposition: MachMsgType.makeSend) }
        let perSender = 120
        var waits: [() -> Int?] = []
        for (i, s) in senders.enumerated() {
            for k in 0..<2 {
                let ctx = w.thread(s)
                waits.append(spawnThread {
                    var ok = 0
                    for n in 0..<perSender {
                        let id = Int32((i * 2 + k) * 100_000 + n)
                        let code: UInt32
                        if n % 2 == 0 {
                            code = w.machMsg2Send(s, ctx, remote: names[i], disposition: MachMsgType.copySend, id: id,
                                                  inline: le32(UInt32(n)), at: SplitWorld.scratch + 0x1000 * UInt64(k + 1),
                                                  fast: true)
                        } else {
                            let m = TestMessage(remote: names[i], remoteDisposition: MachMsgType.copySend, id: id,
                                                inline: le32(UInt32(n)))
                            code = w.machMsg(s, ctx, m.bytes, at: SplitWorld.scratch + 0x1000 * UInt64(k + 1), fast: n % 3 != 0).0
                        }
                        if code == 0 { ok += 1 }
                    }
                    return ok
                })
            }
        }
        let rctx = w.thread(rx)
        var last: [Int32: Int32] = [:]
        var received = 0, outOfOrder = 0
        let expected = senders.count * 2 * perSender
        while received < expected {
            let (code, r) = w.machMsg(rx, rctx, nil, at: SplitWorld.scratch + 0x8000, rcvName: port, rcvTimeoutMs: 10_000,
                                      fast: received % 2 == 0)
            guard code == 0 else { break }
            let stream = r.id / 100_000, seq = r.id % 100_000
            if let prev = last[stream], prev >= seq { outOfOrder += 1 }
            last[stream] = seq
            received += 1
        }
        for wt in waits { #expect(wt() == perSender) }
        #expect(received == expected && outOfOrder == 0)
        #expect(w.fastCount.load(ordering: .relaxed) > expected)
        #expect(w.counters(rx, port)?.msgcount == 0)
    }

    /// Receivers blocked on the fast path when the receive right dies (the
    /// locked path destroys it) all return; senders get their errors; a
    /// dead-name notification reaches its port.
    @Test func portDeathWakesFastWaitersAndNotifies() throws {
        let w = SplitWorld()
        let owner = try w.add(pid: 200), other = try w.add(pid: 201)
        let port = w.allocate(owner)
        let send = w.give(port, from: owner, to: other, disposition: MachMsgType.makeSend)
        let notify = w.allocate(other)
        // Dead-name request on `send` in `other` (mach_port_request_notification, id 72).
        let octx = w.thread(other)
        w.put(other, le32(0), at: SplitWorld.out + 0x100)
        #expect(w.kr(other, octx, -77, [0x103, UInt64(send), 72, 0, UInt64(notify), UInt64(MachMsgType.makeSendOnce),
                                        SplitWorld.out + 0x100]) == 0)
        var receivers: [() -> UInt32?] = []
        for k in 0..<4 {
            let ctx = w.thread(owner)
            receivers.append(spawnThread {
                w.machMsg(owner, ctx, nil, at: SplitWorld.scratch + 0x1000 * UInt64(k + 1), rcvName: port, fast: true).0
            })
        }
        // Let them block, then destroy the receive right on the locked path.
        Thread.sleep(forTimeInterval: 0.1)
        let mctx = w.thread(owner)
        #expect(w.kr(owner, mctx, -19, [0x103, UInt64(port), UInt64(MachPortRight.receive), UInt64(UInt32(bitPattern: -1))]) == 0)
        for r in receivers {
            let code = r()
            #expect(code == MachMsgReturn.rcvPortChanged || code == MachMsgReturn.rcvInvalidName)
        }
        // A send to the dead port (fast path) is not delivered; the dead-name notification arrived.
        let m = TestMessage(remote: send, remoteDisposition: MachMsgType.copySend, id: 7)
        let code = w.machMsg(other, octx, m.bytes, at: SplitWorld.scratch + 0x2000, fast: true).0
        #expect(code == MachMsgReturn.sendInvalidDest)
        let (got, note) = w.machMsg(other, octx, nil, at: SplitWorld.scratch + 0x3000, rcvName: notify, rcvTimeoutMs: 1000,
                                    fast: true)
        #expect(got == 0 && note.id == MachNotify.deadName)
    }

    /// A thread blocked on the fast path (a port-lock wait) is interrupted
    /// by L0's `interrupt` (signal delivery), and the snapshot census sees it.
    @Test func interruptAndCensusReachFineLockWaiters() throws {
        let w = SplitWorld()
        let t = try w.add(pid: 200)
        let port = w.allocate(t)
        let ctx = w.thread(t)
        let result = spawnThread {
            w.machMsg(t, ctx, nil, at: SplitWorld.scratch + 0x1000, rcvName: port, fast: true).0
        }
        var seen = false
        for _ in 0..<200 where !seen {
            Thread.sleep(forTimeInterval: 0.01)
            seen = w.system.lock.withLock { w.system.lock.snapshotWaiterStates.contains { $0.context === ctx && !$0.woken } }
        }
        #expect(seen)
        #expect(w.system.lock.withLock { w.system.lock.interrupt(ctx) })
        #expect(result() == MachMsgReturn.rcvInterrupted)
    }

    /// A woken waiter's signal is sent after the lock is released; timeouts
    /// racing wakes never lose a wakeup (no thread stays blocked).
    @Test func deferredWakesAreNotLost() throws {
        let lock = KernelLock()
        let queue = WaitQueue()
        let woken = Atomic<Int>(0)
        var waits: [() -> Int?] = []
        for _ in 0..<8 {
            waits.append(spawnThread {
                var n = 0
                for i in 0..<300 {
                    let r = lock.withLock { queue.wait(on: lock, deadline: KernelClock.deadline(afterNanoseconds: UInt64(i % 7) * 50_000)) }
                    if r == .woken { n += 1 }
                }
                woken.wrappingAdd(n, ordering: .relaxed)
                return n
            })
        }
        let waker = spawnThread {
            for _ in 0..<5000 {
                lock.withLock { _ = queue.wake(count: 1) }
            }
            return 0
        }
        for wt in waits { #expect(wt() != nil) }
        #expect(waker() == 0)
        #expect(lock.withLock { queue.isEmpty })
    }

    /// The held-lock record follows the order; a fine lock may be taken alone.
    @Test func lockOrderIsRecorded() throws {
        let w = SplitWorld()
        let t = try w.add(pid: 200)
        w.system.lock.withLock {
            let held = KernelThreadLocks.current.held
            #expect(held.count == 1 && held[0] === w.system.lock)
            t.kernel.eventLock!.withLock {
                w.system.mach.portLock!.withLock {
                    #expect(KernelThreadLocks.current.held.map(\.level) == [0, 1, 2])
                }
            }
        }
        #expect(KernelThreadLocks.current.held.isEmpty)
        w.system.mach.portLock!.withLock {
            #expect(KernelThreadLocks.current.held.map(\.level) == [2])
        }
    }

    /// Work posted to a busy event lock runs before the lock is let go; none
    /// is left behind when every thread is done.
    @Test func postedWorkIsNeverLeftBehind() throws {
        let w = SplitWorld()
        let t = try w.add(pid: 200)
        let events = t.kernel.eventLock!
        let done = Atomic<Int>(0)
        let holder = spawnThread { () -> Int in
            for _ in 0..<3000 { events.withLock { for _ in 0..<50 { _ = done.load(ordering: .relaxed) } } }
            return 0
        }
        var posters: [() -> Int?] = []
        for _ in 0..<4 {
            posters.append(spawnThread { () -> Int in
                for _ in 0..<3000 { events.runOrPost { done.wrappingAdd(1, ordering: .relaxed) } }
                return 0
            })
        }
        #expect(holder() == 0)
        for p in posters { #expect(p() == 0) }
        #expect(done.load(ordering: .relaxed) == 12_000)
    }

    /// IPC is off the kernel lock: while another thread holds L0, messages
    /// go back and forth between two images on the fast path.
    @Test func fastPathRunsWhileL0IsHeld() throws {
        let w = SplitWorld()
        let a = try w.add(pid: 200), b = try w.add(pid: 201)
        let port = w.allocate(b)
        let send = w.give(port, from: b, to: a, disposition: MachMsgType.makeSend)
        let actx = w.thread(a), bctx = w.thread(b)
        let held = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let holder = spawnThread { () -> Int in
            w.system.lock.withLock {
                held.signal()
                release.wait()
            }
            return 0
        }
        held.wait()
        // Guest memory is written before (the helpers take L0): direct writes.
        let m = TestMessage(remote: send, remoteDisposition: MachMsgType.copySend, id: 77)
        try a.space.write(va: SplitWorld.scratch + 0x1000, bytes: m.bytes)
        var f = TrapFrame()
        f.kind = TrapFrame.Kind.svc.rawValue
        f.x[16] = UInt64(bitPattern: -31)
        f.x[0] = SplitWorld.scratch + 0x1000
        f.x[1] = MachMsgOption.sendMsg
        f.x[2] = UInt64(m.bytes.count)
        #expect(a.kernel.handleIPCFast(&f, context: actx, memory: a.space) == .resume && f.x[0] == 0)
        var g = TrapFrame()
        g.kind = TrapFrame.Kind.svc.rawValue
        g.x[16] = UInt64(bitPattern: -31)
        g.x[0] = SplitWorld.scratch + 0x2000
        g.x[1] = MachMsgOption.rcvMsg | MachMsgOption.rcvTimeout
        g.x[3] = 0x100
        g.x[4] = UInt64(port)
        g.x[5] = 1000
        #expect(b.kernel.handleIPCFast(&g, context: bctx, memory: b.space) == .resume && g.x[0] == 0)
        let got = Received(try b.space.read(va: SplitWorld.scratch + 0x2000, count: 64))
        #expect(got.id == 77 && got.local == port)
        release.signal()
        #expect(holder() == 0)
    }
}
