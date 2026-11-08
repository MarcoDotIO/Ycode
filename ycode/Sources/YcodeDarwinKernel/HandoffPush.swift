import Foundation
import Synchronization

// The hand-off push (`YCODE_HANDOFF_PUSH`; `specs/simulator/scheduling-policy.md`
// §4.14, `boot-profile.md` §25).
//
// The reference (libdispatch, level 1; behaviour read from the open-source
// `src/queue.c`, `src/inline_internal.h`, `src/event/event_kevent.c` and
// `src/voucher.c`; nothing copied): `dispatch_async` captures, with the work
// item, the dispatching thread's priority (its QoS, which for an XPC handler
// is the request's priority from its kevent) and its voucher (which carries
// the request's importance). Pushing the item to a queue that a workloop
// drains pokes that workloop with a thread request at the item's QoS
// (`EVFILT_WORKLOOP`, `NOTE_WL_THREAD_REQUEST`); the thread that the kernel
// binds to the workloop runs the item at that priority with the voucher
// adopted. So a request taken on one workloop and handed to a queue of
// another is served at the class its sender pushed, by a thread of a task the
// voucher keeps boosted.
//
// Ycode has no vouchers and sees no work items: a thread's turnstile pushes
// (§4.6, §4.12) are not part of the QoS its process asks for, so a handler
// running at a held push hands its work to a thread request at its own QoS
// (often background, or a darwin-bg process), and that thread waits at the
// band's gate while the sender waits for the reply (`boot-profile.md` §24.6,
// `tr-rpe5`). With the switch:
//
// - When a thread that carries a push (§4.6's sync-IPC push or §4.12's held
//   pushes, its own or its workloop's, or a hand-off push) asks for a thread
//   on a workloop of its image other than the one it services (a workloop
//   thread request, new or with its QoS updated), the workloop keeps the
//   highest such class as its *hand-off push*.
// - The thread that next services that workloop carries it from its bind to
//   its unbind (the item's drain), and so does the one servicing it now, if
//   any. It is part of the thread's pushes (§4.4 step 6): above darwin-bg,
//   like the push it came from.
// - Under the image's event lock; the thread's push lock is a leaf.

extension SchedPolicy {
    /// `YCODE_HANDOFF_PUSH` (`1` on, default off until measured): a pushed
    /// thread's workloop thread requests carry its push to the workloop's
    /// next servicer (§4.14).
    nonisolated(unsafe) public static var handoffPushEnabled = flag("YCODE_HANDOFF_PUSH", false) || env("YCODE_HANDOFF_PUSH") == "held"
        || env("YCODE_HANDOFF_PUSH") == "request"
    /// `YCODE_HANDOFF_PUSH=request`: the hand-off is tied to the requests the
    /// dispatching workloop holds (§4.12): the other workloop's servicer
    /// carries their push only until they are answered, not for its drain,
    /// and nothing carries it after the reply (`boot-profile.md` §26.5).
    nonisolated(unsafe) public static var handoffRequestTied = env("YCODE_HANDOFF_PUSH") == "request"
    /// `YCODE_HANDOFF_PUSH=held`: only held reply pushes (§4.12) are carried,
    /// not a sync-IPC push or a hand-off push of the dispatching thread's own
    /// (no chains of hand-offs).
    nonisolated(unsafe) public static var handoffHeldOnly = env("YCODE_HANDOFF_PUSH") == "held"
    @inline(__always) public static var handoffPushActive: Bool { handoffPushEnabled && qosEnabled }
}

extension SchedStats {
    /// Thread requests that carried a push; servicers that took one.
    public static let handoffsMade = Atomic<UInt64>(0)
    public static let handoffsTaken = Atomic<UInt64>(0)
    /// Request-tied hand-offs ended by the last answer of their source.
    public static let handoffsEnded = Atomic<UInt64>(0)

    static var handoffPushReport: String {
        guard SchedPolicy.handoffPushActive else { return "" }
        return "; hand-off pushes \(handoffsMade.load(ordering: .relaxed)) (taken \(handoffsTaken.load(ordering: .relaxed))"
            + (SchedPolicy.handoffRequestTied ? ", ended by the answer \(handoffsEnded.load(ordering: .relaxed))" : "") + ")"
    }
}

extension ThreadContext {
    /// The part of this thread's class that came from pushes a dispatched
    /// item carries (§4.14): sync-IPC, held and hand-off pushes; −1 none.
    var handoffCarriedClass: Int {
        let heldOnly = SchedPolicy.handoffHeldOnly
        return schedPushes.withLock { p in
            max(heldOnly ? -1 : max(p.ipc, p.handoff), HeldPushCounter.maxClass(p.held),
                p.workloop.map { HeldPushCounter.maxClass($0.counts.load(ordering: .relaxed)) } ?? -1)
        }
    }

    /// Sets this thread's hand-off push (−1 none); true when it changed.
    func setHandoffPush(_ cls: Int) -> Bool {
        schedPushes.withLock {
            guard $0.handoff != cls else { return false }
            $0.handoff = cls
            return true
        }
    }
}

extension DarwinKernel {
    /// `context` asked for a thread on workloop `wl` (event lock held).
    func noteWorkloopHandoff(_ wl: KQueue, from context: ThreadContext) {
        guard SchedPolicy.handoffPushActive, context.kernel === self, context.worker?.boundQueue !== wl else { return }
        if SchedPolicy.handoffRequestTied {
            lendHeldRequests(to: wl, from: context)
            return
        }
        let cls = context.handoffCarriedClass
        guard cls > SchedClass.background, cls > wl.handoffClass else { return }
        wl.handoffClass = cls
        SchedStats.handoffsMade.wrappingAdd(1, ordering: .relaxed)
        if !SchedPolicy.syncPushTraced.isEmpty, let name = schedProcessCache?.name, SchedPolicy.syncPushTraced.contains(name) {
            let at = Double(KernelClock.now() &- BackgroundBand.origin) / 1e9
            FileHandle.standardError.write(Data(("ycode-simd: hand-off push: \(name) thread \(context.threadID) class \(SchedClass.name(cls)) "
                + "requests a thread on workloop \(String(wl.workloopID, radix: 16))"
                + "\(wl.servicer.map { " (serviced by thread \($0.threadID))" } ?? "") at \(String(format: "%.2f", at)) s\n").utf8))
        }
        if let s = wl.servicer, s !== context { takeWorkloopHandoff(wl, by: s) }
    }

    /// `ctx` services `wl` (bound, event lock held): it takes the hand-off push.
    func takeWorkloopHandoff(_ wl: KQueue, by ctx: ThreadContext) {
        guard wl.handoffClass >= 0 else { return }
        let cls = max(wl.handoffClass, ctx.schedPushes.withLock { $0.handoff })
        wl.handoffClass = -1
        SchedStats.handoffsTaken.wrappingAdd(1, ordering: .relaxed)
        if ctx.setHandoffPush(cls) { refreshSchedClass(ctx) }
        if !SchedPolicy.syncPushTraced.isEmpty, let name = schedProcessCache?.name, SchedPolicy.syncPushTraced.contains(name) {
            let at = Double(KernelClock.now() &- BackgroundBand.origin) / 1e9
            FileHandle.standardError.write(Data(("ycode-simd: hand-off push: \(name) thread \(ctx.threadID) services workloop "
                + "\(String(wl.workloopID, radix: 16)) at class \(SchedClass.name(cls)) at \(String(format: "%.2f", at)) s\n").utf8))
        }
    }

    /// `YCODE_HANDOFF_PUSH=request`: `context` services a workloop that holds
    /// requests and asks `wl` for a thread: `wl`'s servicer carries those
    /// requests' push until they are answered (event lock held).
    func lendHeldRequests(to wl: KQueue, from context: ThreadContext) {
        guard wl.kind == .workloop, let source = context.worker?.boundQueue?.heldPush,
              source.counts.load(ordering: .relaxed) != 0 else { return }
        let target: HeldPushCounter
        if let existing = wl.heldPush { target = existing } else {
            target = HeldPushCounter()
            wl.heldPush = target
            if let s = wl.servicer { target.attach(s) }
        }
        guard target.lend(from: source) else { return }
        SchedStats.handoffsMade.wrappingAdd(1, ordering: .relaxed)
        if !SchedPolicy.syncPushTraced.isEmpty, let name = schedProcessCache?.name, SchedPolicy.syncPushTraced.contains(name) {
            let at = Double(KernelClock.now() &- BackgroundBand.origin) / 1e9
            FileHandle.standardError.write(Data(("ycode-simd: hand-off push: \(name) thread \(context.threadID) lends its workloop's "
                + "held requests (class \(SchedClass.name(HeldPushCounter.maxClass(source.counts.load(ordering: .relaxed))))) to workloop "
                + "\(String(wl.workloopID, radix: 16))\(wl.servicer.map { " (serviced by thread \($0.threadID))" } ?? "") at \(String(format: "%.2f", at)) s\n").utf8))
        }
    }

    /// `ctx` stopped servicing its workloop: its hand-off push ends.
    func endWorkloopHandoff(_ ctx: ThreadContext) {
        if ctx.setHandoffPush(-1) { refreshSchedClass(ctx) }
    }
}
