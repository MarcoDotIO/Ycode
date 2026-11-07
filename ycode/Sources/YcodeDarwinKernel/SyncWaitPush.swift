import Foundation
import Synchronization

// The sync-wait push (`YCODE_SYNC_PUSH`; `specs/simulator/scheduling-policy.md`
// §4.10, `boot-profile.md` §21).
//
// A thread that sends a request with a send-once reply right and waits for
// the reply in the same call (a synchronous request) pushes its class onto
// whoever will serve the request, from the moment the request is queued, not
// only once a thread has received it (§4.6). On xnu that is the send
// turnstile of the destination port, whose inheritor is the thread or
// workloop that services it, or, for a launchd service port handed to a job
// at spawn (a watch port), the job's main thread; the sender waits on its
// reply port's turnstile, which is linked to that send turnstile, so the push
// follows chains of such waits.
//
// Ycode, under the port lock G (every field here is G state, except the
// image's counts, which the image's threads read without a lock):
//
// - A request queued on a port credits its class to the image that will
//   receive it (`syncPushTarget`): the image of the job the port was given
//   to as a watch port while the port's receive right is still with the
//   spawner or with that job, else the image that holds the receive right.
//   The port keeps the counts it credited and the image it credited them to,
//   so a credit moves when the target changes (at the next enqueue or
//   dequeue on the port, at a spawn that binds it as a watch port, at an
//   exec of the credited process).
// - The image's host class (§4.7) is its threads' own class raised to its
//   send push and to this push. The band (§4.9) lets a waiter go when it
//   rises.
// - When the request is received, the credit ends and the receiving thread
//   carries the request's class as its sync-IPC push (§4.6) until the end of
//   its servicing episode.
// - The sender's wait ends with its trap (the reply came, or the receive
//   failed or timed out): a credit still in place is removed.
// - Chains: when the push on an image changes, every synchronous request
//   that a thread of that image is waiting on is re-evaluated: its class is
//   the sender's class at the send raised to the thread's host class now. A
//   queued request moves its credit; a received one raises the receiving
//   thread's push (never lowers it: that ends with the episode) and goes on
//   to the request that thread waits on, if any. At most
//   `YCODE_SYNC_PUSH_DEPTH` (default 8) hops from the change.

/// One synchronous request and the push it makes (G).
final class SyncWaitPush {
    enum State {
        /// Sent but not queued yet (a full queue, or a kernel object).
        case unsent
        /// In the queue of a port; credited to the port's target.
        case queued(IPCPort)
        /// Received by a thread, which carries the push.
        case received(ThreadContext)
        /// The sender's wait ended.
        case ended
    }

    /// The waiting sender and its image.
    weak var sender: ThreadContext?
    weak var senderImage: DarwinKernel?
    /// The sender's class when it sent; the class the request pushes now.
    let base: Int
    var cls: Int
    var state = State.unsent
    /// When it was queued (trace lines).
    var queuedAt: UInt64 = 0
    /// An on-demand start's push once its message was taken: the image it
    /// is credited to directly (no port any more).
    weak var creditedImage: DarwinKernel?
    /// The reply port of a request on a special reply port, or of a request
    /// whose push is held in the receiving space (§4.12).
    weak var replyPort: IPCPort?
    /// Where the received request's push is held until it is answered (§4.12).
    var hold: ReplyPushHold?

    init(sender: ThreadContext?, image: DarwinKernel?, cls: Int) {
        self.sender = sender
        senderImage = image
        base = cls
        self.cls = cls
    }
}

extension SchedPolicy {
    /// `YCODE_SYNC_PUSH` (with `qosEnabled`): the sync-wait push of §4.10.
    /// `1` on, `0` off (the default until measured; `boot-profile.md` §21).
    nonisolated(unsafe) public static var syncPushEnabled = flag("YCODE_SYNC_PUSH", false)
    /// `YCODE_SYNC_PUSH_DEPTH` (default 8): the most hops a change is passed
    /// on along a chain of synchronous requests.
    nonisolated(unsafe) public static var syncPushDepth = Int(number("YCODE_SYNC_PUSH_DEPTH", 8))
    /// `YCODE_SYNC_PUSH_TRACE=<program>[,<program>...]`: one line when a
    /// request from or to a listed program is queued, moved or received.
    public static let syncPushTraced: Set<String> = {
        guard let v = env("YCODE_SYNC_PUSH_TRACE") else { return [] }
        return Set(v.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
    }()
    /// `YCODE_DEMAND_START_PUSH=<class>` (`bg`, `ut`, `df`, `ui` or 0–3;
    /// unset: off; with the push on): an on-demand start (a watch port with
    /// a message queued at spawn) pushes the job's image at this class until
    /// the job takes the first message off that port (§4.10, "on-demand
    /// starts"; the reference starts such jobs at priority 46, §3).
    nonisolated(unsafe) public static var demandStartClass: Int? = {
        guard let v = env("YCODE_DEMAND_START_PUSH")?.lowercased() else { return nil }
        if let n = Int(v), (0..<SchedClass.count).contains(n) { return n }
        return ["bg": 0, "ut": 1, "df": 2, "ui": 3][v]
    }()
    /// `YCODE_DEMAND_START_MS=N` (with `YCODE_DEMAND_START_PUSH`): the
    /// on-demand start's push lasts N ms from the spawn (and moves to the
    /// image of its exec) instead of until the first request is served.
    nonisolated(unsafe) public static var demandStartNanoseconds: UInt64 = {
        guard let v = env("YCODE_DEMAND_START_MS").flatMap(Double.init), v > 0 else { return 0 }
        return UInt64(v * 1e6)
    }()
    /// True when the push is in force.
    @inline(__always) public static var syncPushActive: Bool { syncPushEnabled && qosEnabled }
}

extension SchedStats {
    /// Synchronous requests that pushed (§4.10); credits moved to a new
    /// target; chain updates (requests re-evaluated after a change) and the
    /// ones stopped at the depth bound.
    public static let syncPushRequests = Atomic<UInt64>(0)
    public static let syncPushMoves = Atomic<UInt64>(0)
    public static let syncPushChainUpdates = Atomic<UInt64>(0)
    public static let syncPushDepthStops = Atomic<UInt64>(0)
    /// Requests whose push was still credited when the sender's wait ended.
    public static let syncPushEndedQueued = Atomic<UInt64>(0)
    /// On-demand starts pushed (`YCODE_DEMAND_START_PUSH`).
    public static let demandStartPushes = Atomic<UInt64>(0)

    static var syncPushReport: String {
        guard SchedPolicy.syncPushActive else { return "" }
        return "; sync-wait pushes \(syncPushRequests.load(ordering: .relaxed)) (moved \(syncPushMoves.load(ordering: .relaxed)), "
            + "chain updates \(syncPushChainUpdates.load(ordering: .relaxed)), depth stops \(syncPushDepthStops.load(ordering: .relaxed)), "
            + "ended queued \(syncPushEndedQueued.load(ordering: .relaxed)))"
            + (SchedPolicy.demandStartClass == nil ? "" : "; on-demand start pushes \(demandStartPushes.load(ordering: .relaxed))")
    }
}

extension DarwinKernel {
    /// The highest class of the synchronous requests queued for this image
    /// (§4.10); −1 none.
    @inline(__always) public var syncPushClass: Int {
        let w = syncPushCounts.load(ordering: .relaxed)
        let timed = demandStartUntil.load(ordering: .relaxed)
        let d = timed != 0 && KernelClock.now() < timed ? Int(timed & 3) : -1
        if w == 0 { return d }
        if w >> 48 != 0 { return 3 }
        if w >> 32 != 0 { return max(2, d) }
        if w >> 16 != 0 { return max(1, d) }
        return max(0, d)
    }

    /// The image-wide pushes (§4.6 send push, §4.10 sync-wait push); −1 none.
    @inline(__always) public var imagePushClass: Int { max(sendPushClass, syncPushClass) }

    /// Adds (or with `sign` −1 removes) `counts` of credit; G held. Returns
    /// whether the image's push class changed.
    @discardableResult
    func changeSyncPush(_ counts: UInt64, sign: Int) -> Bool {
        guard counts != 0 else { return false }
        let before = syncPushClass
        if sign > 0 {
            syncPushCounts.wrappingAdd(counts, ordering: .relaxed)
        } else {
            syncPushCounts.wrappingSubtract(counts, ordering: .relaxed)
        }
        let after = syncPushClass
        if after > SchedClass.background, after > before, BackgroundBand.active { BackgroundBand.poke(kernel: self) }
        return after != before
    }
}

extension ThreadContext {
    /// The class this thread's synchronous requests push (§4.10): its host
    /// class (own class, raised to its image's pushes).
    var syncPushingClass: Int {
        let c = schedClass
        guard let k = kernel else { return c }
        return max(c, k.imagePushClass)
    }
}

extension MachIPC {
    /// The image a request queued on `p` pushes (§4.10), or nil.
    func syncPushTarget(_ p: IPCPort) -> DarwinKernel? {
        guard p.active, !p.isKernelObject else { return nil }
        if let w = p.pushWatchProcess, !w.isZombie, let wk = w.kernel, !wk.isTerminating,
           p.receiver == nil || p.receiver === p.pushWatchHolder || p.receiver?.kernel === wk {
            return wk
        }
        guard let k = p.receiver?.kernel, !k.isTerminating else { return nil }
        return k
    }

    /// Moves `p`'s credit to its current target. G held.
    func rebalanceSyncPush(_ p: IPCPort, depth: Int = 0) {
        // An on-demand start's push lasts only while its job lives.
        if let d = p.demandPush, p.pushWatchProcess.map({ $0.isZombie || $0.kernel == nil }) ?? true {
            endDemandStartPush(p, d, depth: depth)
        }
        let target = syncPushTarget(p)
        guard target !== p.syncPushImage else { return }
        let old = p.syncPushImage
        p.syncPushImage = target
        guard p.syncPushCounts != 0 else { return }
        SchedStats.syncPushMoves.wrappingAdd(1, ordering: .relaxed)
        if !SchedPolicy.syncPushTraced.isEmpty,
           SchedPolicy.syncPushTraced.contains(Self.programName(old)) || SchedPolicy.syncPushTraced.contains(Self.programName(target)) {
            let at = Double(KernelClock.now() &- BackgroundBand.origin) / 1e9
            FileHandle.standardError.write(Data(("ycode-simd: sync push: credit moved from \(Self.programName(old)) to \(Self.programName(target))"
                + " at \(String(format: "%.2f", at)) s\n").utf8))
        }
        if let old {
            old.syncPushPorts.removeValue(forKey: ObjectIdentifier(p))
            if old.changeSyncPush(p.syncPushCounts, sign: -1) { repropagateSyncPush(old, depth: depth + 1) }
        }
        if let target {
            target.syncPushPorts[ObjectIdentifier(p)] = p
            if target.changeSyncPush(p.syncPushCounts, sign: 1) { repropagateSyncPush(target, depth: depth + 1) }
        }
    }

    /// Adds one request of class `cls` to `p`'s credit (`sign` 1) or
    /// removes it (−1). G held.
    func creditSyncPush(_ p: IPCPort, _ cls: Int, sign: Int, depth: Int = 0) {
        guard p.active else { return }
        rebalanceSyncPush(p, depth: depth)
        let u = KernelLock.unit(cls)
        if sign > 0 { p.syncPushCounts &+= u } else { p.syncPushCounts &-= u }
        guard let k = p.syncPushImage else { return }
        if p.syncPushCounts == 0 { k.syncPushPorts.removeValue(forKey: ObjectIdentifier(p)) } else {
            k.syncPushPorts[ObjectIdentifier(p)] = p
        }
        if k.changeSyncPush(u, sign: sign) { repropagateSyncPush(k, depth: depth + 1) }
    }

    /// A port dies: its credit goes. G held.
    func dropSyncPush(_ p: IPCPort) {
        p.demandPush = nil
        guard p.syncPushCounts != 0 else { p.syncPushImage = nil; return }
        let counts = p.syncPushCounts
        p.syncPushCounts = 0
        if let k = p.syncPushImage {
            p.syncPushImage = nil
            k.syncPushPorts.removeValue(forKey: ObjectIdentifier(p))
            if k.changeSyncPush(counts, sign: -1) { repropagateSyncPush(k, depth: 1) }
        }
    }

    /// The send: a synchronous request (send-once reply, receive in the same
    /// call) by `ctx` gets its push record. G held.
    func makeSyncPush(_ m: inout KMessage, ctx: ThreadContext) {
        guard let k = ctx.kernel, let p = m.destination.port, !p.isKernelObject else { return }
        let cls = ctx.syncPushingClass
        m.pushClass = Int8(cls)
        if let old = ctx.syncWait { endSyncWait(ctx, old) }
        let t = SyncWaitPush(sender: ctx, image: k, cls: cls)
        m.syncPush = t
        ctx.syncWait = t
        ctx.waitsOnRequest.store(true, ordering: .releasing)
        k.syncWaiters[ObjectIdentifier(t)] = t
        SchedStats.syncPushRequests.wrappingAdd(1, ordering: .relaxed)
    }

    /// The request joined `p`'s queue. G held.
    func syncPushQueued(_ t: SyncWaitPush, on p: IPCPort) {
        guard case .unsent = t.state else { return }
        t.state = .queued(p)
        creditSyncPush(p, t.cls, sign: 1)
        if !SchedPolicy.syncPushTraced.isEmpty {
            t.queuedAt = KernelClock.now()
            traceSyncPush(t, "queued for \(Self.programName(p.syncPushImage)) (its push now \(p.syncPushImage.map { SchedClass.name($0.syncPushClass) } ?? "-"))",
                          also: p.syncPushImage)
        }
    }

    /// The program name of an image, for trace lines.
    static func programName(_ k: DarwinKernel?) -> String {
        guard let k else { return "nobody" }
        return k.schedProcessCache?.name ?? "pid \(k.pid)"
    }

    /// One trace line about `t` when its sender's or `other`'s program is traced.
    func traceSyncPush(_ t: SyncWaitPush, _ what: String, also other: DarwinKernel?) {
        let sender = Self.programName(t.senderImage)
        let target = Self.programName(other)
        guard SchedPolicy.syncPushTraced.contains(sender) || SchedPolicy.syncPushTraced.contains(target) else { return }
        let at = Double(KernelClock.now() &- BackgroundBand.origin) / 1e9
        let line = "ycode-simd: sync push: \(sender) thread \(t.sender?.threadID ?? 0) class \(SchedClass.name(t.cls)): \(what) at \(String(format: "%.2f", at)) s\n"
        FileHandle.standardError.write(Data(line.utf8))
    }

    /// The request left `p`'s queue (received, or destroyed as too large). G held.
    func syncPushDequeued(_ t: SyncWaitPush, from p: IPCPort) {
        guard case let .queued(q) = t.state, q === p else { return }
        t.state = .ended
        creditSyncPush(p, t.cls, sign: -1)
    }

    /// `context` received the request: it carries its class (§4.6). G held.
    func syncPushReceived(_ t: SyncWaitPush, by context: ThreadContext) {
        guard case .ended = t.state, t.sender != nil, t.senderImage?.syncWaiters[ObjectIdentifier(t)] != nil else { return }
        t.state = .received(context)
        if !SchedPolicy.syncPushTraced.isEmpty, t.queuedAt != 0 {
            traceSyncPush(t, "received by \(Self.programName(context.kernel)) thread \(context.threadID) (class \(SchedClass.name(context.schedClass))) "
                + "after \((KernelClock.now() &- t.queuedAt) / 1_000_000) ms", also: context.kernel)
        }
    }

    /// The end of the sender's trap: its wait for the reply is over. G held.
    func endSyncWait(_ ctx: ThreadContext) {
        guard let t = ctx.syncWait else { return }
        endSyncWait(ctx, t)
    }

    func endSyncWait(_ ctx: ThreadContext, _ t: SyncWaitPush) {
        if ctx.syncWait === t { ctx.syncWait = nil }
        if ctx.syncWait == nil, ctx.replyWait == nil || ctx.replyWait === t { ctx.waitsOnRequest.store(false, ordering: .releasing) }
        t.senderImage?.syncWaiters.removeValue(forKey: ObjectIdentifier(t))
        if t.hold != nil { releaseReplyPush(t, reason: 2) }
        if case let .queued(p) = t.state {
            SchedStats.syncPushEndedQueued.wrappingAdd(1, ordering: .relaxed)
            t.state = .ended
            creditSyncPush(p, t.cls, sign: -1)
        }
        t.state = .ended
    }

    /// The push on `k` changed: re-evaluates the requests its threads wait
    /// on. G held.
    func repropagateSyncPush(_ k: DarwinKernel, depth: Int) {
        guard !k.syncWaiters.isEmpty else { return }
        guard depth <= SchedPolicy.syncPushDepth else {
            SchedStats.syncPushDepthStops.wrappingAdd(1, ordering: .relaxed)
            return
        }
        for t in Array(k.syncWaiters.values) {
            guard let s = t.sender else { continue }
            updateSyncPush(t, to: max(t.base, s.syncPushingClass), depth: depth)
        }
    }

    /// Sets request `t`'s class to `cls` and passes the change on. G held.
    func updateSyncPush(_ t: SyncWaitPush, to cls: Int, depth: Int) {
        guard cls != t.cls else { return }
        SchedStats.syncPushChainUpdates.wrappingAdd(1, ordering: .relaxed)
        let old = t.cls
        switch t.state {
        case let .queued(p):
            t.cls = cls
            guard p.active else { return }
            rebalanceSyncPush(p, depth: depth)
            let delta = KernelLock.unit(cls) &- KernelLock.unit(old)
            p.syncPushCounts &+= delta
            guard let k = p.syncPushImage else { return }
            let before = k.syncPushClass
            k.syncPushCounts.wrappingAdd(delta, ordering: .relaxed)
            let after = k.syncPushClass
            if after > SchedClass.background, after > before, BackgroundBand.active { BackgroundBand.poke(kernel: k) }
            if after != before { repropagateSyncPush(k, depth: depth + 1) }
        case let .received(c):
            // A push held until the reply moves both ways (§4.12).
            if t.hold != nil { moveHeldReplyPush(t, to: cls, depth: depth) }
            // The serving thread's push only rises here; it ends with its episode.
            guard cls > old else { return }
            t.cls = cls
            guard c.isAlive, let ck = c.kernel else { return }
            if c.ipcPushClass < cls {
                c.ipcPushClass = cls
                ck.refreshSchedClass(c)
            }
            guard let next = c.syncWait ?? c.replyWait else { return }
            guard depth < SchedPolicy.syncPushDepth else {
                SchedStats.syncPushDepthStops.wrappingAdd(1, ordering: .relaxed)
                return
            }
            updateSyncPush(next, to: max(next.cls, cls), depth: depth + 1)
        case .unsent, .ended:
            t.cls = cls
        }
    }

    /// Spawn: the job's watch ports (§4.10, xnu's task watchports). G held.
    func bindSyncPushWatchPorts(_ ports: [IPCPort], to child: DarwinProcess) {
        for p in ports where p.active {
            p.pushWatchProcess = child
            p.pushWatchHolder = p.receiver
            rebalanceSyncPush(p)
            if let cls = SchedPolicy.demandStartClass, SchedPolicy.demandStartNanoseconds > 0, !p.messages.isEmpty,
               let k = child.kernel, k.demandStartUntil.load(ordering: .relaxed) == 0 {
                // The timed form: the job's image runs at `cls` for the bound.
                let until = (KernelClock.now() &+ SchedPolicy.demandStartNanoseconds) & ~3 | UInt64(cls)
                k.demandStartUntil.store(until, ordering: .relaxed)
                SchedStats.demandStartPushes.wrappingAdd(1, ordering: .relaxed)
            } else if let cls = SchedPolicy.demandStartClass, SchedPolicy.demandStartNanoseconds == 0, !p.messages.isEmpty, p.demandPush == nil {
                let d = SyncWaitPush(sender: nil, image: nil, cls: cls)
                d.state = .queued(p)
                p.demandPush = d
                creditSyncPush(p, cls, sign: 1)
                SchedStats.demandStartPushes.wrappingAdd(1, ordering: .relaxed)
                if SchedPolicy.syncPushTraced.contains(child.name) {
                    let at = Double(KernelClock.now() &- BackgroundBand.origin) / 1e9
                    FileHandle.standardError.write(Data(("ycode-simd: sync push: on-demand start of \(child.name) pid \(child.pid) at class "
                        + "\(SchedClass.name(cls)) (\(p.messages.count) queued) at \(String(format: "%.2f", at)) s\n").utf8))
                }
            }
        }
    }

    /// The job took the first message off `p`: the on-demand start's push
    /// leaves the port and stays on the job's image until the receiving
    /// thread's servicing episode ends (§4.3), when `context` is known;
    /// else it ends now. G held.
    func handOverDemandStartPush(_ p: IPCPort, to context: ThreadContext?) {
        guard let d = p.demandPush else { return }
        guard let context, let k = p.syncPushImage, p.active, context.demandServing == nil else {
            endDemandStartPush(p, d)
            return
        }
        p.demandPush = nil
        let u = KernelLock.unit(d.cls)
        p.syncPushCounts &-= u
        if p.syncPushCounts == 0 { k.syncPushPorts.removeValue(forKey: ObjectIdentifier(p)) }
        d.state = .received(context)
        d.creditedImage = k
        context.demandServing = d
    }

    /// The end of the servicing episode of a thread that took an on-demand
    /// start's first message. G held.
    func endDemandServing(_ context: ThreadContext) {
        guard let d = context.demandServing else { return }
        context.demandServing = nil
        d.state = .ended
        if let k = d.creditedImage, k.changeSyncPush(KernelLock.unit(d.cls), sign: -1) { repropagateSyncPush(k, depth: 1) }
        d.creditedImage = nil
    }

    /// The on-demand start's push on `p` ends (the job is gone). G held.
    func endDemandStartPush(_ p: IPCPort, _ d: SyncWaitPush, depth: Int = 0) {
        p.demandPush = nil
        d.state = .ended
        guard p.active else { return }
        let u = KernelLock.unit(d.cls)
        p.syncPushCounts &-= u
        guard let k = p.syncPushImage else { return }
        if p.syncPushCounts == 0 { k.syncPushPorts.removeValue(forKey: ObjectIdentifier(p)) }
        if k.changeSyncPush(u, sign: -1) { repropagateSyncPush(k, depth: depth + 1) }
    }

    /// Exec: the credits of the process's old image `old` move to its new one. G held.
    func retargetSyncPushes(from old: DarwinKernel) {
        for p in Array(old.syncPushPorts.values) { rebalanceSyncPush(p) }
        // A timed on-demand start push goes on in the new image.
        let timed = old.demandStartUntil.load(ordering: .relaxed)
        if timed != 0, let next = kernel { next.demandStartUntil.store(timed, ordering: .relaxed) }
    }
}
