import Foundation
import Synchronization
import Testing
import YcodeDarwinABI
@testable import YcodeDarwinKernel

/// The host class of a thread start (`YCODE_START_CLASS`,
/// scheduling-policy.md §4.15): a host thread that takes a guest thread
/// applies that thread's host class before its first instruction (no
/// demotion delay); a host thread that parks below df moves to df; a vCPU
/// creator thread runs at ui. Off, nothing moves.
extension KernelSwitchSuites {
@Suite(.serialized) struct StartClassTests {
    /// Runs `body` on a fresh host thread (its applied class starts unset)
    /// with moves recorded instead of made.
    func onHostThread(startClass: Bool, _ body: @escaping @Sendable () -> Void) -> [Int] {
        schedSwitchesTestLock.lock()
        defer { schedSwitchesTestLock.unlock() }
        let moves = Mutex<[Int]>([])
        let saved = (SchedPolicy.qosEnabled, HostSched.startClassEnabled, HostSched.threadID, HostSched.demoteDelayNanoseconds)
        SchedPolicy.qosEnabled = true
        HostSched.startClassEnabled = startClass
        HostSched.threadID = { 4242 }
        HostSched.demoteDelayNanoseconds = 60_000_000_000  // a demotion through `apply` would wait a minute
        HostSched.moveHook = { _, cls in moves.withLock { $0.append(cls) } }
        defer {
            HostSched.moveHook = nil
            (SchedPolicy.qosEnabled, HostSched.startClassEnabled, HostSched.threadID, HostSched.demoteDelayNanoseconds) = saved
        }
        let done = DispatchSemaphore(value: 0)
        let thread = Thread {
            body()
            done.signal()
        }
        thread.start()
        #expect(done.wait(timeout: .now() + 10) == .success)
        return moves.withLock { $0 }
    }

    func thread(of world: SplitWorld, pid: Int32, cls: Int) throws -> ThreadContext {
        let task = try world.add(pid: pid)
        let ctx = world.thread(task)
        ctx.schedClassStore.store(cls, ordering: .relaxed)
        return ctx
    }

    /// A start applies the new thread's class at once, down as well as up,
    /// where `apply` would have put the fall off by the demotion delay.
    @Test func startTakesTheThreadsClassAtOnce() throws {
        let w = SplitWorld()
        let ui = try thread(of: w, pid: 300, cls: SchedClass.interactive)
        let bg = try thread(of: w, pid: 301, cls: SchedClass.background)
        let moves = onHostThread(startClass: true) {
            HostSched.applyAtStart(ui)
            HostSched.applyAtStart(bg)  // a fall, at once
            HostSched.apply(SchedClass.background)  // already there: no move
            HostSched.applyAtStart(bg)  // no change: no move
        }
        #expect(moves == [SchedClass.interactive, SchedClass.background])
    }

    /// The start class is the host class: raised to the image's send push.
    @Test func startClassIncludesTheImagesPush() throws {
        let w = SplitWorld()
        let ctx = try thread(of: w, pid: 310, cls: SchedClass.background)
        ctx.kernel!.addSendPush(SchedClass.default)
        defer { ctx.kernel!.removeSendPush(SchedClass.default) }
        let moves = onHostThread(startClass: true) { HostSched.applyAtStart(ctx) }
        #expect(moves == [SchedClass.default])
    }

    /// A host thread that parks below df waits at df; one at df or above
    /// stays; one that never applied a class (no guest thread ran) stays.
    @Test func parkMovesOnlyThreadsBelowDefault() {
        let moves = onHostThread(startClass: true) {
            HostSched.applyAtPark()  // nothing applied yet
            HostSched.applyNow(SchedClass.background)
            HostSched.applyAtPark()  // bg -> df
            HostSched.applyNow(SchedClass.interactive)
            HostSched.applyAtPark()  // ui stays
        }
        #expect(moves == [SchedClass.background, SchedClass.default, SchedClass.interactive])
    }

    /// A creator thread runs at ui.
    @Test func creatorThreadRunsAtInteractive() {
        let moves = onHostThread(startClass: true) { HostSched.applyOnCreatorThread() }
        #expect(moves == [SchedClass.interactive])
    }

    /// Off (the default), none of the three moves anything.
    @Test func offMovesNothing() throws {
        let w = SplitWorld()
        let ctx = try thread(of: w, pid: 320, cls: SchedClass.interactive)
        let moves = onHostThread(startClass: false) {
            HostSched.applyAtStart(ctx)
            HostSched.applyAtPark()
            HostSched.applyOnCreatorThread()
        }
        #expect(moves.isEmpty)
    }
}
}
