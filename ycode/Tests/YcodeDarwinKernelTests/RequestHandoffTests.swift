import Foundation
import Synchronization
import Testing
import YcodeDarwinABI
@testable import YcodeDarwinKernel

/// The request-tied hand-off (`YCODE_HANDOFF_PUSH=request`,
/// scheduling-policy.md §4.14, boot-profile.md §26.5): a workloop whose
/// servicer asked it for a thread while its own workloop held requests
/// carries those requests' push until they are answered, and no longer.
extension KernelSwitchSuites {
@Suite(.serialized) struct RequestHandoffTests {
    func withQoS(_ body: () throws -> Void) rethrows {
        schedSwitchesTestLock.lock()
        defer { schedSwitchesTestLock.unlock() }
        let saved = (SchedPolicy.qosEnabled, SchedPolicy.handoffRequestTied)
        SchedPolicy.qosEnabled = true
        SchedPolicy.handoffRequestTied = true
        defer { (SchedPolicy.qosEnabled, SchedPolicy.handoffRequestTied) = saved }
        try body()
    }

    /// The servicer of the lent-to workloop is pushed while the source holds
    /// a request, follows the source's class, and drops back when the
    /// source's last request is answered; a later hand-off lends again.
    @Test func lentPushLastsUntilTheAnswer() throws {
        try withQoS {
            let w = SplitWorld()
            let task = try w.add(pid: 400)
            let servicer = w.thread(task)
            let source = HeldPushCounter(), target = HeldPushCounter()
            // Under L0, so that class refreshes run at once (not deferred as on a fast path).
            func locked<T>(_ body: () -> T) -> T { w.system.lock.withLock { body() } }
            locked { target.attach(servicer) }
            #expect(servicer.schedClass == SchedClass.default)
            locked { source.change(KernelLock.unit(SchedClass.default), sign: 1) }
            #expect(locked { target.lend(from: source) })
            #expect(!locked { target.lend(from: source) })  // once per source
            #expect(target.effectiveMaxClass == SchedClass.default)
            locked { source.change(KernelLock.unit(SchedClass.interactive), sign: 1) }  // a second request, at ui
            #expect(servicer.schedClass == SchedClass.interactive)
            locked { source.change(KernelLock.unit(SchedClass.interactive), sign: -1) }
            #expect(servicer.schedClass == SchedClass.default)
            locked { source.change(KernelLock.unit(SchedClass.default), sign: -1) }  // the last answer
            #expect(target.effectiveMaxClass == -1)
            locked { source.change(KernelLock.unit(SchedClass.interactive), sign: 1) }  // a new request is not lent by itself
            #expect(target.effectiveMaxClass == -1)
            #expect(locked { target.lend(from: source) })
            #expect(servicer.schedClass == SchedClass.interactive)
            locked { target.detach(servicer) }
            #expect(servicer.schedClass == SchedClass.default)
        }
    }

    /// Off (`YCODE_HANDOFF_PUSH` not `request`), a link adds nothing.
    @Test func offLendsNothing() throws {
        schedSwitchesTestLock.lock()
        defer { schedSwitchesTestLock.unlock() }
        let saved = SchedPolicy.handoffRequestTied
        SchedPolicy.handoffRequestTied = false
        defer { SchedPolicy.handoffRequestTied = saved }
        let a = HeldPushCounter(), b = HeldPushCounter()
        a.change(KernelLock.unit(SchedClass.interactive), sign: 1)
        b.lend(from: a)
        #expect(b.effectiveMaxClass == -1)
    }

    /// A counter does not lend to itself, and its own held requests count
    /// with the lent ones.
    @Test func ownAndLentRequestsCombine() throws {
        try withQoS {
            let a = HeldPushCounter(), b = HeldPushCounter()
            #expect(!a.lend(from: a))
            b.change(KernelLock.unit(SchedClass.utility), sign: 1)
            a.change(KernelLock.unit(SchedClass.interactive), sign: 1)
            #expect(b.lend(from: a))
            #expect(b.effectiveMaxClass == SchedClass.interactive)
            a.change(KernelLock.unit(SchedClass.interactive), sign: -1)
            #expect(b.effectiveMaxClass == SchedClass.utility)
        }
    }
}
}
