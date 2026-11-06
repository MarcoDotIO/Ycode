import Foundation
import Synchronization
import Testing
import YcodeDarwinABI
@testable import YcodeDarwinKernel

/// The host class after fast traps and the UI path's CPUs
/// (`HostPlacement.swift`, `boot-profile.md` §12). Serialized: the switches
/// are process-wide.
@Suite(.serialized) struct HostPlacementTests {
    func withQoS(_ body: () throws -> Void) rethrows {
        schedSwitchesTestLock.lock()
        defer { schedSwitchesTestLock.unlock() }
        let saved = SchedPolicy.qosEnabled
        SchedPolicy.qosEnabled = true
        defer { SchedPolicy.qosEnabled = saved }
        try body()
    }

    /// Marks the threads `onNewThread` makes (a thread-specific value): the
    /// hooks are process-wide and other suites' traps run in parallel, so
    /// they count only these.
    static let marker: pthread_key_t = {
        var k = pthread_key_t()
        pthread_key_create(&k, nil)
        return k
    }()
    static var onTestThread: Bool { pthread_getspecific(marker) != nil }

    func onNewThread(_ body: @escaping @Sendable () -> Void) -> Bool {
        let done = DispatchSemaphore(value: 0)
        Thread {
            pthread_setspecific(Self.marker, UnsafeRawPointer(bitPattern: 1))
            body()
            done.signal()
        }.start()
        return done.wait(timeout: .now() + 10) == .success
    }

    @Test func masksKeepTheLastCPUsForTheUIPath() throws {
        let m = try #require(HostSched.cpuMasks(reserving: 3, online: 14))
        #expect(m.all == [0x3FFF])
        #expect(m.others == [0x7FF])
        let wide = try #require(HostSched.cpuMasks(reserving: 2, online: 70))
        #expect(wide.all == [UInt64.max, 0x3F])
        #expect(wide.others == [UInt64.max, 0x0F])
        #expect(HostSched.cpuMasks(reserving: 3, online: 4) == nil)
        #expect(HostSched.cpuMasks(reserving: 0, online: 14) == nil)
    }

    /// A host thread changes its affinity only when it runs a thread of the
    /// other side (a reused VM brings its host threads to a new program).
    @Test func placementChangesOnlyWhenTheSideChanges() {
        let calls = Mutex<[Bool]>([])
        HostSched.placeHook = { ui in if Self.onTestThread { calls.withLock { $0.append(ui) } } }
        defer { HostSched.placeHook = nil }
        #expect(onNewThread {
            for ui in [true, true, false, false, false, true, true] { HostSched.place(uiPath: ui) }
        })
        #expect(calls.withLock { $0 } == [true, false, true])
    }

    /// A blocked sender's push reaches the receiving image's threads at the
    /// end of their fast traps (before: only at the end of a locked trap),
    /// and with `YCODE_HOST_SCHED_UI_PUSHED` it also puts them on the UI
    /// path's CPUs while it lasts.
    @Test func fastTrapEndsApplyTheSendPush() throws {
        try withQoS {
            let w = SplitWorld()
            let rx = try w.add(pid: 200)
            let port = w.allocate(rx)
            #expect(w.system.lock.withLock { rx.ipc.portSetAttributes(port, flavor: 1, info: [1]) } == 0)
            let tx = try w.add(pid: 300)
            let name = w.give(port, from: rx, to: tx, disposition: MachMsgType.makeSend)
            let ctx = w.thread(tx)
            ctx.schedClassStore.store(SchedClass.interactive, ordering: .relaxed)
            let first = TestMessage(remote: name, remoteDisposition: MachMsgType.copySend, id: 1)
            #expect(w.machMsg(tx, ctx, first.bytes, at: SplitWorld.scratch + 0x1000, fast: true).0 == 0)
            let blocked = spawnThread {
                let m = TestMessage(remote: name, remoteDisposition: MachMsgType.copySend, id: 2)
                return Int(w.machMsg(tx, ctx, m.bytes, at: SplitWorld.scratch + 0x2000, fast: true).0)
            }
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline, rx.kernel.sendPushClass != SchedClass.interactive { Thread.sleep(forTimeInterval: 0.005) }
            #expect(rx.kernel.sendPushClass == SchedClass.interactive)

            let rctx = w.thread(rx)
            rctx.schedClassStore.store(SchedClass.utility, ordering: .relaxed)
            let moves = Mutex<[Int]>([]), places = Mutex<[Bool]>([])
            let savedTID = HostSched.threadID, savedSwitch = HostSched.fastTrapClass
            let savedPushed = HostSched.pushedUIMinClass, savedDelay = HostSched.demoteDelayNanoseconds
            HostSched.threadID = { 4242 }
            HostSched.moveHook = { _, cls in if Self.onTestThread { moves.withLock { $0.append(cls) } } }
            HostSched.placeHook = { ui in if Self.onTestThread { places.withLock { $0.append(ui) } } }
            HostSched.demoteDelayNanoseconds = 0
            defer {
                HostSched.moveHook = nil
                HostSched.placeHook = nil
                HostSched.threadID = savedTID
                HostSched.fastTrapClass = savedSwitch
                HostSched.pushedUIMinClass = savedPushed
                HostSched.demoteDelayNanoseconds = savedDelay
            }
            // Off: no class change at a fast trap end; the placement (here the
            // other CPUs: no push placement) is checked all the same.
            HostSched.fastTrapClass = .off
            HostSched.pushedUIMinClass = nil
            #expect(onNewThread { rx.kernel.applyHostPolicyAfterFastTrap(rctx) })
            #expect(moves.withLock { $0 }.isEmpty)
            #expect(places.withLock { $0 } == [false])
            places.withLock { $0.removeAll() }
            // On: the thread takes the push's class; pushed images on the UI CPUs.
            HostSched.fastTrapClass = .full
            HostSched.pushedUIMinClass = SchedClass.default
            #expect(onNewThread { rx.kernel.applyHostPolicyAfterFastTrap(rctx) })
            #expect(moves.withLock { $0 } == [SchedClass.interactive])
            #expect(places.withLock { $0 } == [true])
            // `push`: only the raise to the push, once; no move without one.
            HostSched.fastTrapClass = .push
            moves.withLock { $0.removeAll() }
            #expect(onNewThread {
                rx.kernel.applyHostPolicyAfterFastTrap(rctx)
                rx.kernel.applyHostPolicyAfterFastTrap(rctx)
            })
            #expect(moves.withLock { $0 } == [SchedClass.interactive])
            // The sender gets its slot; the push ends, and so does the placement.
            let (code, r) = w.machMsg(rx, rctx, nil, at: SplitWorld.scratch + 0x8000, rcvName: port, rcvTimeoutMs: 5000, fast: true)
            #expect(code == 0 && r.id == 1)
            #expect(blocked() == 0)
            #expect(rx.kernel.sendPushClass == -1)
            moves.withLock { $0.removeAll() }
            places.withLock { $0.removeAll() }
            #expect(onNewThread { rx.kernel.applyHostPolicyAfterFastTrap(rctx) })
            #expect(moves.withLock { $0 }.isEmpty)   // `push` never lowers
            HostSched.fastTrapClass = .full
            #expect(onNewThread { rx.kernel.applyHostPolicyAfterFastTrap(rctx) })
            #expect(moves.withLock { $0 } == [SchedClass.utility])
            #expect(places.withLock { $0 } == [false, false])   // one new thread each
        }
    }

    /// `YCODE_KEVENT_WRITE_AFTER_PORT_LOCK`: an EVFILT_MACHPORT receive with
    /// the split locks writes the message after the port lock, and a buffer
    /// it cannot write still answers MACH_RCV_INVALID_DATA (the message is
    /// gone), as when the write was made under the lock.
    @Test func keventReceiveWritesAfterThePortLock() throws {
        for after in [true, false] {
            let saved = MachIPC.keventWriteAfterPortLock
            MachIPC.keventWriteAfterPortLock = after
            defer { MachIPC.keventWriteAfterPortLock = saved }
            let w = SplitWorld()
            let rx = try w.add(pid: 200)
            let port = w.allocate(rx)
            let tx = try w.add(pid: 300)
            let name = w.give(port, from: rx, to: tx, disposition: MachMsgType.makeSend)
            let ctx = w.thread(tx), rctx = w.thread(rx)
            for id: Int32 in [5, 6] {
                #expect(w.machMsg2Send(tx, ctx, remote: name, disposition: MachMsgType.copySend, id: id, inline: [1, 2, 3, 4],
                                       at: SplitWorld.scratch + 0x1000, fast: true) == 0)
            }
            let options = UInt32(MachMsgOption.rcvMsg | MachMsgOption.rcvLarge | MachMsgOption.rcvLargeIdentity)
            let buffer = SplitWorld.scratch + 0x10000
            let got = rx.kernel.withEvents {
                rx.ipc.receiveForKevent(port: port, options: options, buffer: buffer, size: 0x200, context: rctx, memory: rx.space)
            }
            #expect(got?.returnCode == 0)
            #expect(Received(w.read(rx, buffer, 64)).id == 5)
            #expect(KernelThreadLocks.current.pendingReceiveWrite == nil && !KernelThreadLocks.current.deferReceiveWrite)
            let bad = rx.kernel.withEvents {
                rx.ipc.receiveForKevent(port: port, options: options, buffer: 0x7_0000_0000, size: 0x200, context: rctx, memory: rx.space)
            }
            #expect(bad?.returnCode == MachMsgReturn.rcvInvalidData)
            #expect(w.counters(rx, port)?.msgcount == 0)
        }
    }
}
