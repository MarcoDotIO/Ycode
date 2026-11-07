import Foundation
import Synchronization

// The reply push (`YCODE_REPLY_PUSH`; `specs/simulator/scheduling-policy.md`
// §4.12, `boot-profile.md` §24).
//
// xnu (level 1; behaviour read from the open-source `osfmk/ipc/ipc_port.c`
// special reply port linkage, `osfmk/kern/turnstile.c`,
// `osfmk/kern/thread_policy.c`; nothing copied): a thread that sends a
// request and waits for its reply pushes its priority onto whoever holds the
// request, for as long as it waits. libdispatch's synchronous send (every
// `xpc_connection_send_message_with_reply_sync`) does it in two calls: it
// sends with the thread's special reply port (`thread_get_special_reply_port`)
// as a send-once reply right, then receives on that port with
// `MACH_RCV_SYNC_WAIT`, naming the destination. The kernel links the special
// reply port's turnstile to the destination's send turnstile while the
// request is queued, and, once a thread or a workloop receives it, to that
// receiver, until the reply goes back through the send-once right (or the
// right is destroyed). The push lifts a darwin-bg thread above its throttle
// ("promote above task"). Ycode modelled only the one-call form, and only
// until the receiving thread's servicing episode ended (§4.6, §4.10); an XPC
// daemon hands the request to a queue and serves it later, unpushed.
//
// Ycode, under the port lock G:
//
// - A send whose reply right is a send-once right to the sending thread's
//   special reply port, without a receive in the same call, gets a push
//   record (`SyncWaitPush`) as the one-call form does (§4.10); the thread
//   keeps it as `replyWait` until a receive with `MACH_RCV_SYNC_WAIT` on that
//   port returns (the reply came, or it failed), its next such send, or its
//   end.
// - Queued, the request credits the image that will receive it (§4.10).
// - Received (either form), the push is tied to the send-once reply right in
//   the receiving space and credits the receiving image (its sync-wait push,
//   §4.10: every thread of it, which xnu narrows to the receiving thread or
//   workloop) until the right leaves that space (the reply is sent with it,
//   it is deallocated or moved on, the space ends), the reply port dies, or
//   the sender's wait ends.
// - Chains (§4.10) move such a credit like a queued one.

extension SchedPolicy {
    /// `YCODE_REPLY_PUSH` (with `qosEnabled`): the reply push of §4.12. `1`
    /// on (a received request pushes the workloop it came through, or the
    /// thread that took it), `image` on with the receiving image pushed
    /// instead (every thread of it), `0` off.
    nonisolated(unsafe) public static var replyPushEnabled = flag("YCODE_REPLY_PUSH", false) || env("YCODE_REPLY_PUSH") == "image"
    /// `YCODE_REPLY_PUSH=image`: a held request pushes the whole receiving image.
    nonisolated(unsafe) public static var replyPushWholeImage = env("YCODE_REPLY_PUSH") == "image"
    /// True when the reply push is in force.
    @inline(__always) public static var replyPushActive: Bool { replyPushEnabled && qosEnabled }
}

extension SchedStats {
    /// Requests sent on a special reply port that pushed; pushes tied to a
    /// reply right in a receiving space; those ended by the reply, by the
    /// right going otherwise, by the sender's wait ending first.
    public static let replyPushRequests = Atomic<UInt64>(0)
    public static let replyPushesHeld = Atomic<UInt64>(0)
    public static let replyPushesAnswered = Atomic<UInt64>(0)
    public static let replyPushesDropped = Atomic<UInt64>(0)
    public static let replyPushesEndedByWait = Atomic<UInt64>(0)
    /// Held pushes carried on with their reply right in another message.
    public static let replyPushesMoved = Atomic<UInt64>(0)
    /// Held pushes put on the workloop the request came through.
    public static let replyPushesOnWorkloops = Atomic<UInt64>(0)
    /// Total and longest life of the held pushes.
    public static let replyPushHeldNanoseconds = Atomic<UInt64>(0)
    public static let replyPushHeldLongest = Atomic<UInt64>(0)

    static var replyPushReport: String {
        guard SchedPolicy.replyPushActive else { return "" }
        let ended = replyPushesAnswered.load(ordering: .relaxed) + replyPushesDropped.load(ordering: .relaxed)
            + replyPushesEndedByWait.load(ordering: .relaxed)
        let mean = ended == 0 ? 0 : replyPushHeldNanoseconds.load(ordering: .relaxed) / ended / 1_000_000
        return "; reply pushes\(SchedPolicy.replyPushWholeImage ? " (whole image)" : ""): special-reply requests \(replyPushRequests.load(ordering: .relaxed)), "
            + "held \(replyPushesHeld.load(ordering: .relaxed)) (on workloops \(replyPushesOnWorkloops.load(ordering: .relaxed))) "
            + "(answered \(replyPushesAnswered.load(ordering: .relaxed)), right gone \(replyPushesDropped.load(ordering: .relaxed)), "
            + "wait ended \(replyPushesEndedByWait.load(ordering: .relaxed)), moved on \(replyPushesMoved.load(ordering: .relaxed)); mean \(mean) ms, "
            + "longest \(replyPushHeldLongest.load(ordering: .relaxed) / 1_000_000) ms)"
    }
}

/// Where a received request's push is held (G).
final class ReplyPushHold {
    weak var holder: MachIPC?
    weak var image: DarwinKernel?
    /// The class it pushes.
    var cls: Int
    let since: UInt64
    /// What it pushes: the workloop it was received through, else the
    /// thread that took it, else (`YCODE_REPLY_PUSH=image`) the whole image.
    var workloop: HeldPushCounter?
    weak var thread: ThreadContext?
    var wholeImage = false

    init(holder: MachIPC, image: DarwinKernel, cls: Int) {
        self.holder = holder
        self.image = image
        self.cls = cls
        since = KernelClock.now()
    }

    /// Adds (`sign` 1) or removes (−1) one push of class `cls` where it is held. G held.
    func apply(_ cls: Int, sign: Int, ipc: MachIPC, depth: Int) {
        let u = KernelLock.unit(cls)
        if wholeImage {
            guard let k = image else { return }
            let before = k.syncPushClass
            if sign > 0 { k.syncPushCounts.wrappingAdd(u, ordering: .relaxed) } else { k.syncPushCounts.wrappingSubtract(u, ordering: .relaxed) }
            let after = k.syncPushClass
            if after > SchedClass.background, after > before, BackgroundBand.active { BackgroundBand.poke(kernel: k) }
            if after != before { ipc.repropagateSyncPush(k, depth: depth + 1) }
        } else if let c = workloop {
            c.change(u, sign: sign)
        } else if let t = thread, t.isAlive {
            t.schedPushes.withLock { if sign > 0 { $0.held &+= u } else { $0.held &-= u } }
            t.kernel?.refreshSchedClass(t)
        }
    }
}

/// The requests held by a workloop until their replies (§4.12), 16 bits per
/// class, and the thread that services the workloop now, which carries
/// their push (xnu: the special reply port's turnstile pushes the workloop
/// that received the request, whichever thread services it).
public final class HeldPushCounter: @unchecked Sendable {
    let counts = Atomic<UInt64>(0)
    private struct Servicer { weak var thread: ThreadContext? }
    /// A leaf lock.
    private let servicer = Mutex<Servicer>(Servicer())

    /// The highest class a packed count word holds; −1 none.
    static func maxClass(_ w: UInt64) -> Int {
        if w == 0 { return -1 }
        if w >> 48 != 0 { return 3 }
        if w >> 32 != 0 { return 2 }
        if w >> 16 != 0 { return 1 }
        return 0
    }

    /// `ctx` services the workloop (bound under its event lock).
    func attach(_ ctx: ThreadContext) {
        servicer.withLock { $0.thread = ctx }
        ctx.schedPushes.withLock { $0.workloop = self }
        if counts.load(ordering: .relaxed) != 0 { ctx.kernel?.refreshSchedClass(ctx) }
    }

    /// `ctx` stopped servicing it.
    func detach(_ ctx: ThreadContext) {
        servicer.withLock { if $0.thread === ctx { $0.thread = nil } }
        let had = ctx.schedPushes.withLock { p -> Bool in
            guard p.workloop === self else { return false }
            p.workloop = nil
            return true
        }
        if had, counts.load(ordering: .relaxed) != 0 { ctx.kernel?.refreshSchedClass(ctx) }
    }

    /// Adds (`sign` 1) or removes (−1) `units` of push; the servicer's class follows.
    func change(_ units: UInt64, sign: Int) {
        if sign > 0 { counts.wrappingAdd(units, ordering: .relaxed) } else { counts.wrappingSubtract(units, ordering: .relaxed) }
        if let t = servicer.withLock({ $0.thread }), t.isAlive { t.kernel?.refreshSchedClass(t) }
    }
}

extension MachIPC {
    /// The send of a request on the sending thread's special reply port
    /// (§4.12): its push record, kept by the thread until its sync-wait
    /// receive returns. G held.
    func makeReplyPush(_ m: inout KMessage, ctx: ThreadContext, reply: IPCPort) {
        guard let k = ctx.kernel, let p = m.destination.port, !p.isKernelObject,
              reply.isSpecialReply, specialReplyPorts[ctx.threadID] === reply else { return }
        let cls = ctx.syncPushingClass
        m.pushClass = Int8(cls)
        if let old = ctx.replyWait {
            if !SchedPolicy.syncPushTraced.isEmpty { traceSyncPush(old, "replaced by a new special-reply request", also: old.hold?.image) }
            endReplyWait(ctx, old)
        }
        let t = SyncWaitPush(sender: ctx, image: k, cls: cls)
        t.replyPort = reply
        m.syncPush = t
        ctx.replyWait = t
        ctx.waitsOnRequest.store(true, ordering: .releasing)
        k.syncWaiters[ObjectIdentifier(t)] = t
        SchedStats.replyPushRequests.wrappingAdd(1, ordering: .relaxed)
    }

    /// A receive with `MACH_RCV_SYNC_WAIT` on `port` by `ctx` returned: the
    /// thread's wait for its reply is over. G held.
    func replyWaitReturned(_ ctx: ThreadContext, on port: IPCPort) {
        guard let t = ctx.replyWait, t.replyPort === port else { return }
        if !SchedPolicy.syncPushTraced.isEmpty { traceSyncPush(t, "sender's sync-wait receive returned", also: t.hold?.image) }
        endReplyWait(ctx, t)
    }

    /// Ends the special-reply request `t` of `ctx`. G held.
    func endReplyWait(_ ctx: ThreadContext, _ t: SyncWaitPush) {
        if ctx.replyWait === t { ctx.replyWait = nil }
        endSyncWait(ctx, t)
    }

    /// `context` (a thread of this space) received the request `t`, whose
    /// reply right is a send-once right to `reply`: the push is held in this
    /// space until the right leaves it. G held.
    func holdReplyPush(_ t: SyncWaitPush, reply: IPCPort, image: DarwinKernel, context: ThreadContext) {
        guard t.hold == nil, t.sender != nil, t.senderImage?.syncWaiters[ObjectIdentifier(t)] != nil, reply.active else { return }
        let h = ReplyPushHold(holder: self, image: image, cls: t.cls)
        t.hold = h
        t.replyPort = reply
        reply.replyPushes.append(t)
        SchedStats.replyPushesHeld.wrappingAdd(1, ordering: .relaxed)
        var target = "thread \(context.threadID)"
        if SchedPolicy.replyPushWholeImage {
            h.wholeImage = true
            target = "the image"
        } else if image.eventLock.map({ $0.isHeldByCurrentThread }) ?? true, let w = context.worker, let kq = w.boundQueue,
                  kq.kind == .workloop {
            // Received through a workloop (its event lock held): the workloop is pushed.
            let c: HeldPushCounter
            if let existing = kq.heldPush { c = existing } else {
                c = HeldPushCounter()
                kq.heldPush = c
                if let s = kq.servicer { c.attach(s) }
            }
            h.workloop = c
            target = "workloop \(String(kq.workloopID, radix: 16))"
            SchedStats.replyPushesOnWorkloops.wrappingAdd(1, ordering: .relaxed)
        } else {
            h.thread = context
        }
        h.apply(h.cls, sign: 1, ipc: self, depth: 0)
        if !SchedPolicy.syncPushTraced.isEmpty {
            traceSyncPush(t, "held by \(Self.programName(image)) (\(target)) until its reply", also: image)
        }
    }

    /// A send-once right to `p` left this space (`answered`: as a reply's
    /// destination): the first push this space holds for it ends. G held.
    func replyPushRightLeft(_ p: IPCPort, answered: Bool) {
        guard let i = p.replyPushes.firstIndex(where: { $0.hold?.holder === self }) else { return }
        let t = p.replyPushes.remove(at: i)
        releaseReplyPush(t, reason: answered ? 0 : 1)
    }

    /// The send-once right to `p` is moved on as the reply right of the
    /// message this space is sending: the push this space holds for it leaves
    /// this image and goes with that message (`carryReplyPush`). G held.
    func replyPushMoved(_ p: IPCPort) {
        guard let i = p.replyPushes.firstIndex(where: { $0.hold?.holder === self }) else { return }
        let t = p.replyPushes.remove(at: i)
        releaseReplyPush(t, reason: 3)
        movedReplyPush = t
    }

    /// The message `m` carries the moved right: its push is queued with it
    /// and held again by whoever receives it. G held.
    func carryReplyPush(_ t: SyncWaitPush, in m: inout KMessage) {
        guard m.syncPush == nil, case let .sendOnce(r) = m.reply, r === t.replyPort, t.sender != nil,
              t.senderImage?.syncWaiters[ObjectIdentifier(t)] != nil else { return }
        t.state = .unsent
        m.syncPush = t
        m.pushClass = max(m.pushClass, Int8(t.cls))
        SchedStats.replyPushesMoved.wrappingAdd(1, ordering: .relaxed)
    }

    /// The reply port died: every push held for it ends. G held.
    func dropReplyPushes(_ p: IPCPort) {
        let all = p.replyPushes
        p.replyPushes = []
        for t in all { releaseReplyPush(t, reason: 1) }
    }

    /// Takes `t`'s held credit off the receiving image. `reason`: 0 the
    /// reply, 1 the right gone otherwise, 2 the sender's wait ended, 3 the
    /// right moved on with another message (counted when it is carried). G held.
    func releaseReplyPush(_ t: SyncWaitPush, reason: Int) {
        guard let h = t.hold else { return }
        t.hold = nil
        if !SchedPolicy.syncPushTraced.isEmpty {
            let why = ["answered", "right gone", "sender's wait ended", "right moved on"][min(reason, 3)]
            traceSyncPush(t, "released by \(Self.programName(h.image)) (\(why)) after \((KernelClock.now() &- h.since) / 1_000_000) ms", also: h.image)
        }
        if reason == 2, let r = t.replyPort, let i = r.replyPushes.firstIndex(where: { $0 === t }) { r.replyPushes.remove(at: i) }
        switch reason {
        case 0: SchedStats.replyPushesAnswered.wrappingAdd(1, ordering: .relaxed)
        case 1: SchedStats.replyPushesDropped.wrappingAdd(1, ordering: .relaxed)
        case 2: SchedStats.replyPushesEndedByWait.wrappingAdd(1, ordering: .relaxed)
        default: break
        }
        let life = reason == 3 ? 0 : KernelClock.now() &- h.since
        SchedStats.replyPushHeldNanoseconds.wrappingAdd(life, ordering: .relaxed)
        var longest = SchedStats.replyPushHeldLongest.load(ordering: .relaxed)
        while life > longest {
            let (done, now) = SchedStats.replyPushHeldLongest.compareExchange(expected: longest, desired: life, ordering: .relaxed)
            if done { break }
            longest = now
        }
        h.apply(h.cls, sign: -1, ipc: self, depth: 0)
    }

    /// The class of `ctx` changed (a ulock push, a boost, a QoS change):
    /// the requests it waits on are re-evaluated (§4.12, xnu's turnstile
    /// chains through a lock owner into its request). G held.
    func passThreadClass(_ ctx: ThreadContext) {
        // Nested passes (a chain update refreshes a serving thread's class) are bounded like chains.
        guard Self.threadClassPasses < SchedPolicy.syncPushDepth else {
            SchedStats.syncPushDepthStops.wrappingAdd(1, ordering: .relaxed)
            return
        }
        Self.threadClassPasses += 1
        defer { Self.threadClassPasses -= 1 }
        for t in [ctx.syncWait, ctx.replyWait].compactMap({ $0 }) {
            updateSyncPush(t, to: max(t.base, ctx.syncPushingClass), depth: Self.threadClassPasses)
        }
    }

    /// The depth of nested `passThreadClass` calls (G state: one holder at a time).
    nonisolated(unsafe) static var threadClassPasses = 0

    /// A chain update reached the held request `t` (§4.10): its credit moves
    /// to `cls`. G held.
    func moveHeldReplyPush(_ t: SyncWaitPush, to cls: Int, depth: Int) {
        guard let h = t.hold, cls != h.cls else { return }
        h.apply(cls, sign: 1, ipc: self, depth: depth)
        h.apply(h.cls, sign: -1, ipc: self, depth: depth)
        h.cls = cls
    }
}
