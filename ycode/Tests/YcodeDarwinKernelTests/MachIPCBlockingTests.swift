import Foundation
import Testing
import YcodeDarwinABI
@testable import YcodeDarwinKernel

/// Blocking sends and receives with real host threads (stage4a-contract.md
/// §2: one kernel lock, waits release it).
@Suite(.serialized) struct MachIPCBlockingTests {
    let rcv = MachMsgOption.rcvMsg

    /// Runs `body` on a new host thread; returns a way to wait for its result.
    func spawn<T: Sendable>(_ body: @escaping @Sendable () -> T) -> () -> T? {
        let done = DispatchSemaphore(value: 0)
        let box = ResultBox<T>()
        let thread = Thread {
            box.value = body()
            done.signal()
        }
        thread.start()
        return {
            done.wait(timeout: .now() + 10) == .success ? box.value : nil
        }
    }

    @Test func receiveBlocksUntilAnotherThreadSends() throws {
        let env = try IPCEnv()
        let p = env.allocate()
        let worker = ThreadContext(threadID: 2, portName: env.ipc.allocateThreadPort(), vcpuIndex: 1, kind: .pthread)
        let buffer = IPCEnv.scratch + 0x10000
        let wait = spawn { env.kr(-31, [buffer, MachMsgOption.rcvMsg, 0, 0x100, UInt64(p), 0, 0], context: worker) }
        Thread.sleep(forTimeInterval: 0.05)
        #expect(env.lock.withLock { worker.blockedInKernel })
        #expect(env.send(TestMessage(remote: p, remoteDisposition: MachMsgType.makeSend, id: 99).bytes) == 0)
        #expect(wait() == 0)
        #expect(Received(env.read(buffer, 64)).id == 99)
    }

    @Test func blockedSenderWakesWhenTheQueueDrains() throws {
        let env = try IPCEnv()
        let (_, p) = env.construct(flags: MachPortConstruct.qlimit, qlimit: 1)
        #expect(env.send(TestMessage(remote: p, remoteDisposition: MachMsgType.makeSend, id: 1).bytes) == 0)
        let worker = ThreadContext(threadID: 2, portName: env.ipc.allocateThreadPort(), vcpuIndex: 1, kind: .pthread)
        let sendBuffer = IPCEnv.scratch + 0x10000
        env.put(TestMessage(remote: p, remoteDisposition: MachMsgType.makeSend, id: 2).bytes, at: sendBuffer)
        let wait = spawn { env.kr(-31, [sendBuffer, MachMsgOption.sendMsg, 24, 0, 0, 0, 0], context: worker) }
        Thread.sleep(forTimeInterval: 0.05)
        #expect(env.ipc.portCounters(p)?.msgcount == 1)
        let (code, raw) = env.receive(p)
        #expect(code == 0 && Received(raw).id == 1)
        #expect(wait() == 0)
        let (code2, raw2) = env.receive(p)
        #expect(code2 == 0 && Received(raw2).id == 2)
    }

    /// `mach-ipc.md` §2.9 (`YCODE_PORT_SLOT_HANDOFF`, boot-profile.md §8):
    /// a receive from a full queue wakes the oldest blocked sender only and
    /// keeps the freed slot for it; a sender that arrives meanwhile finds the
    /// queue still full; the second blocked sender stays asleep until the
    /// next receive. Messages arrive in the senders' blocking order.
    @Test func dequeueHandsTheSlotToTheOldestBlockedSender() throws {
        let env = try IPCEnv()
        let (_, p) = env.construct(flags: MachPortConstruct.qlimit, qlimit: 1)
        #expect(env.send(TestMessage(remote: p, remoteDisposition: MachMsgType.makeSend, id: 1).bytes) == 0)
        let first = ThreadContext(threadID: 2, portName: env.ipc.allocateThreadPort(), vcpuIndex: 1, kind: .pthread)
        let second = ThreadContext(threadID: 3, portName: env.ipc.allocateThreadPort(), vcpuIndex: 2, kind: .pthread)
        let b1 = IPCEnv.scratch + 0x10000, b2 = IPCEnv.scratch + 0x11000
        env.put(TestMessage(remote: p, remoteDisposition: MachMsgType.makeSend, id: 2).bytes, at: b1)
        env.put(TestMessage(remote: p, remoteDisposition: MachMsgType.makeSend, id: 3).bytes, at: b2)
        let wait1 = spawn { env.kr(-31, [b1, MachMsgOption.sendMsg, 24, 0, 0, 0, 0], context: first) }
        Thread.sleep(forTimeInterval: 0.05)
        let wait2 = spawn { env.kr(-31, [b2, MachMsgOption.sendMsg, 24, 0, 0, 0, 0], context: second) }
        Thread.sleep(forTimeInterval: 0.05)
        #expect(env.lock.withLock { first.blockedInKernel && second.blockedInKernel })
        let (code, raw) = env.receive(p)
        #expect(code == 0 && Received(raw).id == 1)
        #expect(wait1() == 0)
        // The second sender was not woken by that receive.
        #expect(env.lock.withLock { second.blockedInKernel })
        #expect(env.send(TestMessage(remote: p, remoteDisposition: MachMsgType.makeSend, id: 4).bytes,
                         options: MachMsgOption.sendMsg | MachMsgOption.sendTimeout) == MachMsgReturn.sendTimedOut)
        let (c2, r2) = env.receive(p)
        #expect(c2 == 0 && Received(r2).id == 2)
        #expect(wait2() == 0)
        let (c3, r3) = env.receive(p)
        #expect(c3 == 0 && Received(r3).id == 3)
        #expect(env.ipc.portCounters(p)?.msgcount == 0)
    }

    @Test func blockedReceiverGetsPortChanged() throws {
        let env = try IPCEnv()
        let p = env.allocate()
        let worker = ThreadContext(threadID: 2, portName: env.ipc.allocateThreadPort(), vcpuIndex: 1, kind: .pthread)
        let buffer = IPCEnv.scratch + 0x10000
        let wait = spawn { env.kr(-31, [buffer, MachMsgOption.rcvMsg, 0, 0x100, UInt64(p), 0, 0], context: worker) }
        Thread.sleep(forTimeInterval: 0.05)
        #expect(env.modRefs(p, MachPortRight.receive, -1) == 0)
        #expect(wait() == MachMsgReturn.rcvPortChanged)

        // Adding the port to a set while a thread waits on it: PORT_CHANGED too.
        let q = env.allocate(), set = env.allocate(MachPortRight.portSet)
        let wait2 = spawn { env.kr(-31, [buffer, MachMsgOption.rcvMsg, 0, 0x100, UInt64(q), 0, 0], context: worker) }
        Thread.sleep(forTimeInterval: 0.05)
        #expect(env.kr(-22, [env.task, UInt64(q), UInt64(set)]) == 0)
        #expect(wait2() == MachMsgReturn.rcvPortChanged)
    }

    @Test func blockedSetReceiverWakesForAMember() throws {
        let env = try IPCEnv()
        let a = env.allocate(), b = env.allocate(), set = env.allocate(MachPortRight.portSet)
        #expect(env.kr(-22, [env.task, UInt64(a), UInt64(set)]) == 0)
        let worker = ThreadContext(threadID: 2, portName: env.ipc.allocateThreadPort(), vcpuIndex: 1, kind: .pthread)
        let buffer = IPCEnv.scratch + 0x10000
        let wait = spawn { env.kr(-31, [buffer, MachMsgOption.rcvMsg, 0, 0x100, UInt64(set), 0, 0], context: worker) }
        Thread.sleep(forTimeInterval: 0.05)
        // Joining the set with a queued message makes the set ready.
        #expect(env.send(TestMessage(remote: b, remoteDisposition: MachMsgType.makeSend, id: 5).bytes) == 0)
        #expect(env.kr(-22, [env.task, UInt64(b), UInt64(set)]) == 0)
        #expect(wait() == 0)
        let r = Received(env.read(buffer, 64))
        #expect(r.id == 5 && r.local == b)
    }

    @Test func receiveTimeoutWithAnotherThreadIdle() throws {
        let env = try IPCEnv()
        let p = env.allocate()
        let worker = ThreadContext(threadID: 2, portName: env.ipc.allocateThreadPort(), vcpuIndex: 1, kind: .pthread)
        let buffer = IPCEnv.scratch + 0x10000
        let start = Date()
        let wait = spawn {
            env.kr(-31, [buffer, MachMsgOption.rcvMsg | MachMsgOption.rcvTimeout, 0, 0x100, UInt64(p), 80, 0],
                   context: worker)
        }
        // The lock is free while it waits: the main thread can still use IPC.
        Thread.sleep(forTimeInterval: 0.02)
        #expect(env.allocate() != 0)
        #expect(wait() == MachMsgReturn.rcvTimedOut)
        #expect(Date().timeIntervalSince(start) >= 0.075)
    }

    @Test func directHandoffBypassesAZeroQueueLimit() throws {
        let env = try IPCEnv()
        let (_, p) = env.construct(flags: MachPortConstruct.qlimit, qlimit: 0)
        // No receiver waiting: a zero-limit queue is full.
        #expect(env.send(TestMessage(remote: p, remoteDisposition: MachMsgType.makeSend).bytes,
                         options: MachMsgOption.sendMsg | MachMsgOption.sendTimeout) == MachMsgReturn.sendTimedOut)
        let worker = ThreadContext(threadID: 2, portName: env.ipc.allocateThreadPort(), vcpuIndex: 1, kind: .pthread)
        let buffer = IPCEnv.scratch + 0x10000
        let wait = spawn { env.kr(-31, [buffer, MachMsgOption.rcvMsg, 0, 0x100, UInt64(p), 0, 0], context: worker) }
        Thread.sleep(forTimeInterval: 0.05)
        #expect(env.send(TestMessage(remote: p, remoteDisposition: MachMsgType.copySend, id: 3).bytes,
                         options: MachMsgOption.sendMsg | MachMsgOption.sendTimeout) == 0)
        #expect(wait() == 0)
        #expect(Received(env.read(buffer, 64)).id == 3)
    }

    @Test func interruptedWaits() throws {
        let env = try IPCEnv()
        let p = env.allocate()
        let worker = ThreadContext(threadID: 2, portName: env.ipc.allocateThreadPort(), vcpuIndex: 1, kind: .pthread)
        let buffer = IPCEnv.scratch + 0x10000
        let wait = spawn { env.kr(-31, [buffer, MachMsgOption.rcvMsg, 0, 0x100, UInt64(p), 0, 0], context: worker) }
        Thread.sleep(forTimeInterval: 0.05)
        #expect(env.lock.withLock { env.lock.interrupt(worker) })
        #expect(wait() == MachMsgReturn.rcvInterrupted)
        // A blocked send is interrupted the same way (and pseudo-received).
        let (_, q) = env.construct(flags: MachPortConstruct.qlimit, qlimit: 0)
        env.put(TestMessage(remote: q, remoteDisposition: MachMsgType.makeSend).bytes, at: buffer)
        let wait2 = spawn { env.kr(-31, [buffer, MachMsgOption.sendMsg, 24, 0, 0, 0, 0], context: worker) }
        Thread.sleep(forTimeInterval: 0.05)
        #expect(env.lock.withLock { env.lock.interrupt(worker) })
        #expect(wait2() == MachMsgReturn.sendInterrupted)
        #expect(env.type(q) == (0, MachPortType.send | MachPortType.receive))
    }

    @Test func manyThreadsPingPong() throws {
        let env = try IPCEnv()
        let server = env.allocate()
        #expect(env.insertRight(server, server, MachMsgType.makeSend) == 0)
        let count = 4, rounds = 25
        // A server thread echoes every request to its reply port.
        let serverContext = ThreadContext(threadID: 10, portName: env.ipc.allocateThreadPort(), vcpuIndex: 9,
                                          kind: .pthread)
        let serverBuffer = IPCEnv.scratch + 0x20000
        let served = spawn { () -> Int in
            var n = 0
            while n < count * rounds {
                let k = env.kr(-31, [serverBuffer, MachMsgOption.rcvMsg, 0, 0x100, UInt64(server), 0, 0],
                               context: serverContext)
                guard k == 0 else { return -1 }
                let r = Received(env.read(serverBuffer, 64))
                let answer = TestMessage(remote: r.remote, remoteDisposition: MachMsgType.moveSendOnce, id: r.id + 100)
                env.put(answer.bytes, at: serverBuffer)
                guard env.kr(-31, [serverBuffer, MachMsgOption.sendMsg, 24, 0, 0, 0, 0], context: serverContext) == 0 else {
                    return -2
                }
                n += 1
            }
            return n
        }
        var clients: [() -> Int?] = []
        for c in 0..<count {
            let context = ThreadContext(threadID: UInt64(20 + c), portName: env.ipc.allocateThreadPort(), vcpuIndex: c,
                                        kind: .pthread)
            let buffer = IPCEnv.scratch + 0x30000 + UInt64(c) * 0x800
            let reply = env.allocate()
            clients.append(spawn { () -> Int in
                var ok = 0
                for i in 0..<rounds {
                    let m = TestMessage(remote: server, remoteDisposition: MachMsgType.copySend, local: reply,
                                        localDisposition: MachMsgType.makeSendOnce, id: Int32(c * 1000 + i))
                    env.put(m.bytes, at: buffer)
                    let k = env.kr(-31, [buffer, MachMsgOption.sendMsg | MachMsgOption.rcvMsg, 24, 0x100, UInt64(reply),
                                         0, 0], context: context)
                    if k == 0, Received(env.read(buffer, 64)).id == Int32(c * 1000 + i + 100) { ok += 1 }
                }
                return ok
            })
        }
        for c in clients { #expect(c() == rounds) }
        #expect(served() == count * rounds)
        #expect(env.ipc.portCounters(server)?.srights == 1)
    }

    @Test func messageQueuedHandlerAndKevent() throws {
        let env = try IPCEnv()
        let p = env.allocate(), set = env.allocate(MachPortRight.portSet)
        #expect(env.kr(-22, [env.task, UInt64(p), UInt64(set)]) == 0)
        let seen = LineBox()
        env.ipc.messageQueuedHandler = { seen.append(String($0, radix: 16)) }
        #expect(env.send(TestMessage(remote: p, remoteDisposition: MachMsgType.makeSend, id: 4,
                                     inline: [1, 2, 3, 4]).bytes) == 0)
        #expect(seen.all == [String(p, radix: 16), String(set, radix: 16)])
        #expect(env.ipc.receiveTarget(of: set) == .portSet)
        #expect(env.ipc.receiveTarget(of: p) == .port)
        #expect(env.ipc.receiveTarget(of: 0x103) == .notReceivable)
        #expect(env.ipc.receiveTarget(of: 0x55503) == .none)
        // A kevent receive: never waits; too small → TOO_LARGE with the needed size.
        let buffer = IPCEnv.scratch + 0x10000
        let large = UInt32(MachMsgOption.rcvMsg | MachMsgOption.rcvLarge | MachMsgOption.rcvLargeIdentity) | 7 << 24
        let small = env.ipc.receiveForKevent(port: set, options: large, buffer: buffer, size: 16, context: env.main,
                                             memory: env.space)
        #expect(small?.returnCode == MachMsgReturn.rcvTooLarge && small?.size == 28 + 68 && small?.data == UInt64(p))
        let got = env.ipc.receiveForKevent(port: set, options: large, buffer: buffer, size: 0x100, context: env.main,
                                           memory: env.space)
        #expect(got?.returnCode == 0 && got?.size == 28 + 68)
        #expect(Received(env.read(buffer, 64)).id == 4)
        let none = env.ipc.receiveForKevent(port: set, options: large, buffer: buffer, size: 0x100, context: env.main,
                                            memory: env.space)
        #expect(none?.returnCode == MachMsgReturn.rcvTimedOut)
    }
}

final class ResultBox<T>: @unchecked Sendable {
    var value: T?
}
