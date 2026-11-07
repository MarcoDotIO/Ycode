import Foundation
import Testing
@testable import YcodeDarwinKernel

/// The hand-off push (`YCODE_HANDOFF_PUSH`, scheduling-policy.md §4.14): a
/// thread that carries a push and asks for a thread on another workloop of
/// its image leaves the push to that workloop's next servicer, for its drain.
extension KernelSwitchSuites {
@Suite(.serialized) struct HandoffPushTests {
    func with(on: Bool, _ body: () throws -> Void) rethrows {
        schedSwitchesTestLock.lock()
        defer { schedSwitchesTestLock.unlock() }
        let saved = (SchedPolicy.qosEnabled, SchedPolicy.handoffPushEnabled)
        SchedPolicy.qosEnabled = true
        SchedPolicy.handoffPushEnabled = on
        defer { (SchedPolicy.qosEnabled, SchedPolicy.handoffPushEnabled) = saved }
        try body()
    }

    /// An image with a dispatching thread `a` that carries an interactive held
    /// push (on the workloop it services) and two more darwin-bg threads.
    struct Setup {
        let w = SplitWorld()
        let task: TaskWorld.Task
        let a: ThreadContext, b: ThreadContext, c: ThreadContext
        let held = HeldPushCounter()

        init() throws {
            task = try w.add(pid: 200)
            a = w.thread(task)
            b = w.thread(task)
            c = w.thread(task)
            for t in [a, b, c] {
                t.threadDarwinBG = true
                w.system.lock.withLock { task.kernel.refreshSchedClass(t) }
            }
            let (held, a) = (held, a)
            w.system.lock.withLock {
                held.attach(a)
                held.change(KernelLock.unit(SchedClass.interactive), sign: 1)
            }
        }
    }

    @Test func theNextServicerOfTheWorkloopCarriesThePush() throws {
        try with(on: true) {
            let s = try Setup()
            #expect(s.a.schedClass == SchedClass.interactive)
            #expect(s.b.schedClass == SchedClass.background)
            let wl = KQueue(kind: .workloop, workloopID: 0x1000)
            let k = s.task.kernel
            s.w.system.lock.withLock { k.noteWorkloopHandoff(wl, from: s.a) }
            #expect(wl.handoffClass == SchedClass.interactive)
            s.w.system.lock.withLock { k.takeWorkloopHandoff(wl, by: s.b) }
            #expect(s.b.schedClass == SchedClass.interactive)
            #expect(wl.handoffClass == -1)
            // A later servicer gets nothing; the drain's end ends the push.
            s.w.system.lock.withLock { k.takeWorkloopHandoff(wl, by: s.c) }
            #expect(s.c.schedClass == SchedClass.background)
            s.w.system.lock.withLock { k.endWorkloopHandoff(s.b) }
            #expect(s.b.schedClass == SchedClass.background)
        }
    }

    @Test func aServicerAlreadyBoundIsPushedAtOnce() throws {
        try with(on: true) {
            let s = try Setup()
            let wl = KQueue(kind: .workloop, workloopID: 0x2000)
            wl.servicer = s.b
            s.w.system.lock.withLock { s.task.kernel.noteWorkloopHandoff(wl, from: s.a) }
            #expect(s.b.schedClass == SchedClass.interactive)
            s.w.system.lock.withLock { s.task.kernel.endWorkloopHandoff(s.b) }
            #expect(s.b.schedClass == SchedClass.background)
        }
    }

    @Test func anUnpushedThreadLeavesNothing() throws {
        try with(on: true) {
            let s = try Setup()
            let wl = KQueue(kind: .workloop, workloopID: 0x3000)
            // b's class is its own (background): nothing to carry.
            s.w.system.lock.withLock { s.task.kernel.noteWorkloopHandoff(wl, from: s.b) }
            #expect(wl.handoffClass == -1)
        }
    }

    @Test func offWithoutTheSwitch() throws {
        try with(on: false) {
            let s = try Setup()
            let wl = KQueue(kind: .workloop, workloopID: 0x4000)
            s.w.system.lock.withLock { s.task.kernel.noteWorkloopHandoff(wl, from: s.a) }
            #expect(wl.handoffClass == -1)
        }
    }
    @Test func theHeldFormCarriesNoHandoffOfItsOwn() throws {
        try with(on: true) {
            let saved = SchedPolicy.handoffHeldOnly
            SchedPolicy.handoffHeldOnly = true
            defer { SchedPolicy.handoffHeldOnly = saved }
            let s = try Setup()
            let k = s.task.kernel
            let wl = KQueue(kind: .workloop, workloopID: 0x5000), wl2 = KQueue(kind: .workloop, workloopID: 0x6000)
            s.w.system.lock.withLock { k.noteWorkloopHandoff(wl, from: s.a); k.takeWorkloopHandoff(wl, by: s.b) }
            #expect(s.b.schedClass == SchedClass.interactive)
            // b's push is a hand-off, not a held request: it is not passed on.
            s.w.system.lock.withLock { k.noteWorkloopHandoff(wl2, from: s.b) }
            #expect(wl2.handoffClass == -1)
        }
    }
}
}
