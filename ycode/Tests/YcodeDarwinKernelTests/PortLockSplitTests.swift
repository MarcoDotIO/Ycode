import Foundation
import Synchronization
import Testing
import YcodeDarwinABI
@testable import YcodeDarwinKernel

/// The port lock split (`specs/simulator/mach-ipc-locking.md` §4.12,
/// `YCODE_PORT_LOCK_SPLIT=1`): G shared for fine steps, a lock per space.
/// The switch is process-wide (it is read when a system is made), so the
/// suite runs among the switch suites, with the lock-order check on.
extension KernelSwitchSuites {
    @Suite(.serialized) struct PortLockSplitTests {
        /// Runs `body` with the split on (systems made inside get it).
        static func withSplit<T>(_ body: () throws -> T) rethrows -> T {
            let old = PortLockSplit.enabled
            PortLockSplit.enabled = true
            defer { PortLockSplit.enabled = old }
            return try body()
        }

        static func served(_ k: PortLockSplit.Kind) -> UInt64 { PortLockSplit.served[k.rawValue].load }
        static func declined(_ r: PortLockSplit.Reason) -> UInt64 { PortLockSplit.declines[r.rawValue].load }

        /// Moves the receive right of `name` from `from` to `to` under L0 and
        /// G (exclusive), as a message would. The new name in `to`.
        static func moveReceive(_ w: SplitWorld, _ name: UInt32, from: TaskWorld.Task, to: TaskWorld.Task) -> UInt32 {
            w.system.lock.withLock {
                w.system.mach.portLock!.withLock {
                    guard case let .success(r) = from.ipc.copyin(name, MachMsgType.moveReceive, slot: .body, apply: true) else {
                        preconditionFailure("copyin of the receive right failed")
                    }
                    return to.ipc.copyout(r).name
                }
            }
        }

        // MARK: The lock itself

        /// Exclusive holders exclude shared ones: a writer makes a counter odd
        /// for the length of its hold; no shared holder ever sees it odd, and
        /// both sides make progress.
        @Test func exclusiveHoldersExcludeSharedOnes() throws {
            try Self.withSplit {
                let system = DarwinSystem(ipcLocks: true)
                let g = try #require(system.mach.portLock)
                #expect(g.sharesReaders)
                let value = UnsafeMutablePointer<Int>.allocate(capacity: 1)
                value.initialize(to: 0)
                defer { value.deallocate() }
                let box = UnsafeSendable(value)
                let stop = Atomic<Bool>(false)
                let oddSeen = Atomic<Int>(0), sharedHolds = Atomic<Int>(0)
                var readers: [() -> Int?] = []
                for _ in 0..<4 {
                    readers.append(spawnThread {
                        var n = 0
                        while !stop.load(ordering: .relaxed) {
                            guard g.tryAcquireShared() else { continue }
                            if box.value.pointee & 1 != 0 { oddSeen.wrappingAdd(1, ordering: .relaxed) }
                            g.releaseShared()
                            n += 1
                        }
                        sharedHolds.wrappingAdd(n, ordering: .relaxed)
                        return n
                    })
                }
                let writer = spawnThread { () -> Int in
                    for _ in 0..<20_000 {
                        g.withLock {
                            box.value.pointee += 1
                            for _ in 0..<20 { _ = KernelClock.now() }
                            box.value.pointee += 1
                        }
                    }
                    return 0
                }
                #expect(writer() == 0)
                stop.store(true, ordering: .relaxed)
                for r in readers { #expect(r() != nil) }
                #expect(oddSeen.load(ordering: .relaxed) == 0)
                #expect(sharedHolds.load(ordering: .relaxed) > 0)
                #expect(value.pointee == 40_000)
            }
        }

        /// Space locks are taken in increasing space id (the order check is
        /// on): a step that needs a space of a lower id than its own lets go
        /// and takes them again in order; one that needs a higher one takes
        /// it on top. Both happen in request/reply traffic between an image
        /// made first (lower id) and one made later.
        @Test func spaceLocksAreTakenInIncreasingOrder() throws {
            try Self.withSplit {
                let w = SplitWorld()
                let low = try w.add(pid: 200), high = try w.add(pid: 300)
                #expect(low.ipc.spaceID < high.ipc.spaceID)
                let port = w.allocate(low)
                let reply = w.allocate(high)
                let send = w.give(port, from: low, to: high, disposition: MachMsgType.makeSend)
                let onTop = PortLockSplit.lockedOnTop.load, again = PortLockSplit.relocked.load
                let hctx = w.thread(high), lctx = w.thread(low)
                for n in 0..<50 {
                    // high -> low with a reply right of high's: spaces {high, low}, taken again in order.
                    let m = TestMessage(remote: send, remoteDisposition: MachMsgType.copySend, local: reply,
                                        localDisposition: MachMsgType.makeSend, id: Int32(n))
                    #expect(w.machMsg(high, hctx, m.bytes, at: SplitWorld.scratch + 0x1000, fast: true).0 == 0)
                    // low receives it: the reply's send right merges into low's name for it, a port of
                    // high's: spaces {low, high}, high's taken on top.
                    let (code, r) = w.machMsg(low, lctx, nil, at: SplitWorld.scratch + 0x2000, rcvName: port, rcvTimeoutMs: 0,
                                              fast: true)
                    #expect(code == 0 && r.id == Int32(n))
                }
                #expect(PortLockSplit.relocked.load > again)
                #expect(PortLockSplit.lockedOnTop.load > onTop)
                let k = w.counters(high, reply)
                #expect(k?.srights == 1 && k?.msgcount == 0)
            }
        }

        // MARK: Fine steps

        /// Simple sends (both traps) from three images and the receiver's
        /// polls run as fine steps; blocking receives decline. Every message
        /// arrives once, each sender's in order; rights balance.
        @Test func fineStepsCarrySimpleTrafficInOrder() throws {
            try Self.withSplit {
                let w = SplitWorld()
                let rx = try w.add(pid: 200)
                let port = w.allocate(rx)
                #expect(w.system.lock.withLock { rx.ipc.portSetAttributes(port, flavor: 1, info: [64]) } == 0)
                let senders = try (0..<3).map { try w.add(pid: 300 + Int32($0)) }
                let names = senders.map { w.give(port, from: rx, to: $0, disposition: MachMsgType.makeSend) }
                let sendsBefore = Self.served(.send), receivesBefore = Self.served(.receive)
                let perThread = 300
                var waits: [() -> Int?] = []
                for (i, s) in senders.enumerated() {
                    for k in 0..<2 {
                        let ctx = w.thread(s)
                        waits.append(spawnThread {
                            var ok = 0
                            for n in 0..<perThread {
                                let id = Int32((i * 2 + k) * 100_000 + n)
                                let buffer = SplitWorld.scratch + 0x1000 * UInt64(k + 1)
                                let code: UInt32
                                if n % 2 == 0 {
                                    code = w.machMsg2Send(s, ctx, remote: names[i], disposition: MachMsgType.copySend, id: id,
                                                          inline: le32(UInt32(n)), at: buffer, fast: true)
                                } else {
                                    let m = TestMessage(remote: names[i], remoteDisposition: MachMsgType.copySend, id: id,
                                                        inline: le32(UInt32(n)))
                                    code = w.machMsg(s, ctx, m.bytes, at: buffer, sendTimeoutMs: 10_000, fast: true).0
                                }
                                if code == 0 { ok += 1 }
                            }
                            return ok
                        })
                    }
                }
                let rctx = w.thread(rx)
                var last: [Int32: Int32] = [:]
                var received = 0, outOfOrder = 0, bad = 0
                let expected = senders.count * 2 * perThread
                var turn = 0
                while received < expected {
                    turn += 1
                    let (code, r) = w.machMsg(rx, rctx, nil, at: SplitWorld.scratch + 0x8000, rcvName: port,
                                              rcvTimeoutMs: turn % 4 == 0 ? 10_000 : 0, fast: true)
                    if code == MachMsgReturn.rcvTimedOut { continue }
                    guard code == 0 else { bad += 1; break }
                    let stream = r.id / 100_000, seq = r.id % 100_000
                    if let prev = last[stream], prev >= seq { outOfOrder += 1 }
                    if r.u32(24) != UInt32(seq) { bad += 1 }
                    last[stream] = seq
                    received += 1
                }
                for wt in waits { #expect(wt() == perThread) }
                #expect(received == expected && outOfOrder == 0 && bad == 0)
                #expect(Self.served(.send) > sendsBefore)
                #expect(Self.served(.receive) > receivesBefore)
                let c = w.counters(rx, port)
                #expect(c?.msgcount == 0 && c?.srights == senders.count && c?.sorights == 0)
            }
        }

        /// Replies that carry a send right (merged into an existing name or a
        /// new one) and send-once replies answered with MOVE_SEND_ONCE, the
        /// server dropping the send rights with `mach_port_deallocate`: the
        /// counts come back to where they started.
        @Test func replyRightsAndDeallocateBalance() throws {
            try Self.withSplit {
                let w = SplitWorld()
                let server = try w.add(pid: 200)
                let service = w.allocate(server)
                let clients = try (0..<3).map { try w.add(pid: 300 + Int32($0)) }
                let names = clients.map { w.give(service, from: server, to: $0, disposition: MachMsgType.makeSend) }
                let replies = clients.map { w.allocate($0) }
                let deallocsBefore = Self.served(.deallocate)
                let rounds = 200
                let total = clients.count * rounds
                let done = Atomic<Int>(0)
                let sctx = w.thread(server)
                let serverWait = spawnThread { () -> Int in
                    var n = 0
                    while done.load(ordering: .relaxed) < total {
                        let (code, r) = w.machMsg(server, sctx, nil, at: SplitWorld.scratch + 0x1000, rcvName: service,
                                                  rcvTimeoutMs: 0, fast: true)
                        if code == MachMsgReturn.rcvTimedOut { continue }
                        guard code == 0 else { return -1 }
                        if r.id % 2 == 0 {
                            // A send right: answer on it (COPY_SEND), then drop it.
                            let answer = TestMessage(remote: r.remote, remoteDisposition: MachMsgType.copySend, id: r.id + 1)
                            guard w.machMsg(server, sctx, answer.bytes, at: SplitWorld.scratch + 0x1000, sendTimeoutMs: 10_000,
                                            fast: true).0 == 0 else { return -2 }
                            guard w.kr(server, sctx, -18, [0x103, UInt64(r.remote)], fast: true) == 0 else { return -3 }
                        } else {
                            let answer = TestMessage(remote: r.remote, remoteDisposition: MachMsgType.moveSendOnce, id: r.id + 1)
                            guard w.machMsg(server, sctx, answer.bytes, at: SplitWorld.scratch + 0x1000, fast: true).0 == 0 else {
                                return -4
                            }
                        }
                        n += 1
                        done.wrappingAdd(1, ordering: .relaxed)
                    }
                    return n
                }
                var waits: [() -> Int?] = []
                for (ci, c) in clients.enumerated() {
                    let ctx = w.thread(c)
                    waits.append(spawnThread {
                        var ok = 0
                        for r in 0..<rounds {
                            let id = Int32(ci * 100_000 + r * 2) + Int32(r % 2)
                            let disposition = id % 2 == 0 ? MachMsgType.makeSend : MachMsgType.makeSendOnce
                            let m = TestMessage(remote: names[ci], remoteDisposition: MachMsgType.copySend, local: replies[ci],
                                                localDisposition: disposition, id: id)
                            guard w.machMsg(c, ctx, m.bytes, at: SplitWorld.scratch + 0x2000, sendTimeoutMs: 10_000,
                                            fast: true).0 == 0 else { continue }
                            var got = false
                            for _ in 0..<1000 where !got {
                                let (code, a) = w.machMsg(c, ctx, nil, at: SplitWorld.scratch + 0x3000, rcvName: replies[ci],
                                                          rcvTimeoutMs: 10_000, fast: true)
                                if code == 0, a.id == id + 1 { got = true }
                            }
                            if got { ok += 1 }
                        }
                        return ok
                    })
                }
                for wt in waits { #expect(wt() == rounds) }
                #expect(serverWait() == total)
                for (ci, c) in clients.enumerated() {
                    let k = w.counters(c, replies[ci])
                    #expect(k?.srights == 0 && k?.sorights == 0 && k?.msgcount == 0)
                }
                let s = w.counters(server, service)
                #expect(s?.srights == clients.count && s?.msgcount == 0)
                #expect(Self.served(.deallocate) > deallocsBefore)
            }
        }

        /// The receive right dies while clients send to it (fine steps) and
        /// messages are queued: every message a client sent comes back to it
        /// as exactly one send-once notification (from the server's
        /// deallocation of the reply right it received, or from the queued
        /// message's destruction), and no right is left over.
        @Test func portDeathWhileMessagesAreQueued() throws {
            try Self.withSplit {
                let w = SplitWorld()
                let server = try w.add(pid: 200)
                let client = try w.add(pid: 300)
                let reply = w.allocate(client)
                let sctx = w.thread(server)
                let contexts = (0..<3).map { _ in w.thread(client) }
                var sentTotal = 0
                for round in 0..<25 {
                    let port = w.allocate(server)
                    let name = w.give(port, from: server, to: client, disposition: MachMsgType.makeSend)
                    var waits: [() -> Int?] = []
                    for (j, ctx) in contexts.enumerated() {
                        waits.append(spawnThread {
                            var sent = 0
                            for n in 0..<10_000 {
                                let m = TestMessage(remote: name, remoteDisposition: MachMsgType.copySend, local: reply,
                                                    localDisposition: MachMsgType.makeSendOnce, id: Int32(n))
                                let code = w.machMsg(client, ctx, m.bytes, at: SplitWorld.scratch + 0x1000 * UInt64(j + 1),
                                                     fast: true).0
                                if code != 0 { break }
                                sent += 1
                            }
                            return sent
                        })
                    }
                    // Receive a few (dropping each reply right: a notification), then destroy the port.
                    var taken = 0
                    while taken < 3 + round % 5 {
                        let (code, r) = w.machMsg(server, sctx, nil, at: SplitWorld.scratch + 0x8000, rcvName: port,
                                                  rcvTimeoutMs: 1000, fast: true)
                        guard code == 0 else { break }
                        #expect(w.kr(server, sctx, -18, [0x103, UInt64(r.remote)], fast: round % 2 == 0) == 0)
                        taken += 1
                    }
                    #expect(w.kr(server, sctx, -19, [0x103, UInt64(port), UInt64(MachPortRight.receive),
                                                     UInt64(UInt32(bitPattern: -1))], fast: round % 3 == 0) == 0)
                    for wt in waits { sentTotal += wt() ?? -1_000_000 }
                    // The client's dead name goes too.
                    _ = w.kr(client, contexts[0], -18, [0x103, UInt64(name)], fast: true)
                }
                // Drain the notifications.
                var notes = 0
                let cctx = contexts[0]
                while true {
                    let (code, r) = w.machMsg(client, cctx, nil, at: SplitWorld.scratch + 0x9000, rcvName: reply,
                                              rcvTimeoutMs: 0, fast: notes % 2 == 0)
                    guard code == 0 else { break }
                    if r.id == MachNotify.sendOnce { notes += 1 }
                }
                #expect(sentTotal > 0)
                #expect(notes == sentTotal)
                let k = w.counters(client, reply)
                #expect(k?.sorights == 0 && k?.msgcount == 0)
            }
        }

        /// The receive right moves between two images (under G exclusive)
        /// while each image's thread polls it (fine receives) and a third
        /// image sends to it (fine sends): every message is received once.
        @Test func receiveRightMovesWhileOthersReceive() throws {
            try Self.withSplit {
                let w = SplitWorld()
                let a = try w.add(pid: 200), b = try w.add(pid: 201), c = try w.add(pid: 300)
                let first = w.allocate(a)
                #expect(w.system.lock.withLock { a.ipc.portSetAttributes(first, flavor: 1, info: [64]) } == 0)
                let send = w.give(first, from: a, to: c, disposition: MachMsgType.makeSend)
                // NSLock, not Synchronization.Mutex: ThreadSanitizer does not
                // see the latter's futex on Linux.
                let holder = LockedBox<(pid: Int32, name: UInt32)>((200, first))
                let stop = Atomic<Bool>(false)
                let perSender = 400
                let seen = LockedBox<[Int32: Int]>([:])
                func receiver(_ t: TaskWorld.Task) -> () -> Int? {
                    let ctx = w.thread(t)
                    return spawnThread {
                        var n = 0
                        while !stop.load(ordering: .relaxed) {
                            let (pid, name) = holder.withLock { $0 }
                            guard pid == t.kernel.pid else { continue }
                            let (code, r) = w.machMsg(t, ctx, nil, at: SplitWorld.scratch + 0x8000, rcvName: name,
                                                      rcvTimeoutMs: n % 7 == 0 ? 2 : 0, fast: true)
                            if code == 0 {
                                seen.withLock { $0[r.id, default: 0] += 1 }
                                n += 1
                            }
                        }
                        return n
                    }
                }
                let ra = receiver(a), rb = receiver(b)
                var senders: [() -> Int?] = []
                for k in 0..<2 {
                    let ctx = w.thread(c)
                    senders.append(spawnThread {
                        var ok = 0
                        for n in 0..<perSender {
                            let m = TestMessage(remote: send, remoteDisposition: MachMsgType.copySend, id: Int32(k * 100_000 + n))
                            if w.machMsg(c, ctx, m.bytes, at: SplitWorld.scratch + 0x1000 * UInt64(k + 1), sendTimeoutMs: 20_000,
                                         fast: true).0 == 0 { ok += 1 }
                        }
                        return ok
                    })
                }
                let mover = spawnThread { () -> Int in
                    var moves = 0
                    while moves < 200 {
                        holder.withLock { h in
                            let from = h.pid == 200 ? a : b, to = h.pid == 200 ? b : a
                            h = (to.kernel.pid, Self.moveReceive(w, h.name, from: from, to: to))
                        }
                        moves += 1
                        Thread.sleep(forTimeInterval: 0.0005)
                    }
                    return moves
                }
                for s in senders { #expect(s() == perSender) }
                #expect(mover() == 200)
                // Drain what is left from the final holder.
                var drained = 0
                let (pid, name) = holder.withLock { $0 }
                let last = pid == 200 ? a : b
                let lctx = w.thread(last)
                stop.store(true, ordering: .relaxed)
                _ = ra()
                _ = rb()
                while true {
                    let (code, r) = w.machMsg(last, lctx, nil, at: SplitWorld.scratch + 0x9000, rcvName: name, rcvTimeoutMs: 0,
                                              fast: true)
                    guard code == 0 else { break }
                    seen.withLock { $0[r.id, default: 0] += 1 }
                    drained += 1
                }
                let counts = seen.withLock { $0 }
                #expect(counts.count == 2 * perSender)
                #expect(counts.values.allSatisfy { $0 == 1 })
                #expect(w.counters(last, name)?.msgcount == 0)
            }
        }

        /// A port moves in and out of a port set (port routines under G
        /// exclusive) while messages are sent to both members (fine steps)
        /// and received through the set and the member (fine receives).
        @Test func portSetMembershipChangesUnderFineSteps() throws {
            try Self.withSplit {
                let w = SplitWorld()
                let a = try w.add(pid: 200), c = try w.add(pid: 300)
                let p1 = w.allocate(a), p2 = w.allocate(a)
                let set = w.allocate(a, MachPortRight.portSet)
                let actx = w.thread(a)
                #expect(w.kr(a, actx, -22, [0x103, UInt64(p1), UInt64(set)]) == 0)
                for p in [p1, p2] {
                    #expect(w.system.lock.withLock { a.ipc.portSetAttributes(p, flavor: 1, info: [64]) } == 0)
                }
                let s1 = w.give(p1, from: a, to: c, disposition: MachMsgType.makeSend)
                let s2 = w.give(p2, from: a, to: c, disposition: MachMsgType.makeSend)
                let perSender = 400
                let stop = Atomic<Bool>(false)
                var senders: [() -> Int?] = []
                for (k, name) in [s1, s2].enumerated() {
                    let ctx = w.thread(c)
                    senders.append(spawnThread {
                        var ok = 0
                        for n in 0..<perSender {
                            let m = TestMessage(remote: name, remoteDisposition: MachMsgType.copySend, id: Int32(k * 100_000 + n))
                            if w.machMsg(c, ctx, m.bytes, at: SplitWorld.scratch + 0x1000 * UInt64(k + 1), sendTimeoutMs: 20_000,
                                         fast: true).0 == 0 { ok += 1 }
                        }
                        return ok
                    })
                }
                let tctx = w.thread(a)
                let toggler = spawnThread { () -> Int in
                    var n = 0
                    while !stop.load(ordering: .relaxed) {
                        _ = w.kr(a, tctx, n % 2 == 0 ? -22 : -23, [0x103, UInt64(p2), UInt64(set)], fast: n % 3 != 0)
                        n += 1
                    }
                    return n
                }
                let seen = LockedBox<[Int32: Int]>([:])
                let rctx = w.thread(a)
                var received = 0, turn = 0
                while received < 2 * perSender && turn < 5_000_000 {
                    turn += 1
                    let name = turn % 3 == 0 ? p2 : set
                    let (code, r) = w.machMsg(a, rctx, nil, at: SplitWorld.scratch + 0x8000, rcvName: name, rcvTimeoutMs: 0,
                                              fast: true)
                    guard code == 0 else { continue }
                    seen.withLock { $0[r.id, default: 0] += 1 }
                    received += 1
                }
                stop.store(true, ordering: .relaxed)
                #expect(toggler() != nil)
                for s in senders { #expect(s() == perSender) }
                let counts = seen.withLock { $0 }
                #expect(counts.count == 2 * perSender && counts.values.allSatisfy { $0 == 1 })
                #expect(w.counters(a, p1)?.msgcount == 0 && w.counters(a, p2)?.msgcount == 0)
            }
        }

        /// A send that would wake a blocked receiver declines (the locked
        /// path wakes it); the message still arrives.
        @Test func aSendToABlockedReceiverDeclines() throws {
            try Self.withSplit {
                let w = SplitWorld()
                let rx = try w.add(pid: 200), tx = try w.add(pid: 300)
                let port = w.allocate(rx)
                let send = w.give(port, from: rx, to: tx, disposition: MachMsgType.makeSend)
                let rctx = w.thread(rx)
                let result = spawnThread {
                    w.machMsg(rx, rctx, nil, at: SplitWorld.scratch + 0x1000, rcvName: port, rcvTimeoutMs: 10_000, fast: true)
                }
                var blocked = false
                for _ in 0..<500 where !blocked {
                    Thread.sleep(forTimeInterval: 0.002)
                    blocked = w.system.lock.withLock { w.system.mach.portLock!.withLock { rx.ipc.blockedReceivers(port) > 0 } }
                }
                #expect(blocked)
                let before = Self.declined(.waiters)
                let m = TestMessage(remote: send, remoteDisposition: MachMsgType.copySend, id: 99)
                #expect(w.machMsg(tx, w.thread(tx), m.bytes, at: SplitWorld.scratch + 0x2000, fast: true).0 == 0)
                #expect(Self.declined(.waiters) > before)
                let got = result()
                #expect(got?.0 == 0 && got?.1.id == 99)
            }
        }

        /// The kevent EVFILT_MACHPORT receive (under the image's event lock,
        /// as the kernel calls it) runs as a fine step while senders run
        /// theirs; every message arrives once; a bad buffer still answers
        /// MACH_RCV_INVALID_DATA with the message gone. The end of a
        /// servicing episode with a push class is a fine step too.
        @Test func keventReceivesAndServicingEndsAreFineSteps() throws {
            try Self.withSplit {
                let w = SplitWorld()
                let rx = try w.add(pid: 200)
                let port = w.allocate(rx)
                #expect(w.system.lock.withLock { rx.ipc.portSetAttributes(port, flavor: 1, info: [64]) } == 0)
                let senders = try (0..<2).map { try w.add(pid: 300 + Int32($0)) }
                let names = senders.map { w.give(port, from: rx, to: $0, disposition: MachMsgType.makeSend) }
                let before = Self.served(.keventReceive)
                let perSender = 400
                var waits: [() -> Int?] = []
                for (i, s) in senders.enumerated() {
                    let ctx = w.thread(s)
                    waits.append(spawnThread {
                        (0..<perSender).filter { n in
                            w.machMsg2Send(s, ctx, remote: names[i], disposition: MachMsgType.copySend, id: Int32(i * 100_000 + n),
                                           inline: le32(UInt32(n)), at: SplitWorld.scratch + 0x1000 * UInt64(i + 1), fast: true) == 0
                        }.count
                    })
                }
                let rctx = w.thread(rx)
                let options = UInt32(MachMsgOption.rcvMsg | MachMsgOption.rcvLarge | MachMsgOption.rcvLargeIdentity)
                let buffer = SplitWorld.scratch + 0x10000
                var seen: [Int32: Int] = [:]
                var invalid = 0, spins = 0
                while seen.count + invalid < senders.count * perSender && spins < 50_000_000 {
                    spins += 1
                    let bad = spins % 97 == 0
                    guard let got = rx.kernel.withEvents({
                        rx.ipc.receiveForKevent(port: port, options: options, buffer: bad ? 0x7_0000_0000 : buffer, size: 0x200,
                                                context: rctx, memory: rx.space)
                    }) else { break }
                    if got.returnCode == MachMsgReturn.rcvInvalidData { invalid += 1; continue }
                    guard got.returnCode == 0 else { continue }
                    seen[Received(w.read(rx, buffer, 64)).id, default: 0] += 1
                }
                for wt in waits { #expect(wt() == perSender) }
                #expect(seen.values.allSatisfy { $0 == 1 })
                #expect(seen.count + invalid == senders.count * perSender)
                #expect(Self.served(.keventReceive) > before)
                #expect(w.counters(rx, port)?.msgcount == 0)
                // A servicing episode's push class ends on a fine step.
                let servicingBefore = Self.served(.servicing)
                rctx.ipcPushClass = SchedClass.interactive
                #expect(rx.ipc.fineEndServicing(rctx))
                #expect(rctx.ipcPushClass == -1)
                #expect(Self.served(.servicing) == servicingBefore + 1)
            }
        }

        // MARK: The existing storms, with the split on

        @Test func lockSplitStormsWithTheSplit() throws {
            try Self.withSplit {
                let suite = MachIPCLockSplitTests()
                try suite.requestReplyStormAcrossImages()
                try suite.kqueueHookWakesTheServerBeforeTheClientSleeps()
                try suite.fullQueueBlocksSendersAndKeepsOrder()
                try suite.portDeathWakesFastWaitersAndNotifies()
                try suite.interruptAndCensusReachFineLockWaiters()
                try suite.portRoutinesOnTheFastPathKeepRightsBalanced()
                let race = ThreadStateRaceTests()
                try race.threadGetStateWhileTargetsTakeFastPaths()
                try race.entryFrameReadUnderL0WhileTargetTakesFastPaths()
                print("ycode-test: " + PortLockSplit.report)
            }
            #expect(Self.served(.send) > 0 && Self.served(.receive) > 0 && Self.served(.deallocate) > 0 && Self.served(.query) > 0)
            #expect(Self.served(.threadState) > 0)
        }
    }
}

/// A value behind an NSLock (`withLock` as `Mutex`'s).
final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func withLock<R>(_ body: (inout Value) throws -> R) rethrows -> R {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }
}

/// A pointer passed to test threads.
struct UnsafeSendable<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

extension MachIPC {
    /// Tests: the receivers blocked on the port `name` (G held).
    func blockedReceivers(_ name: UInt32) -> Int {
        guard let i = slot(of: name), let p = entries[i].port else { return 0 }
        return p.waitingReceivers
    }
}
