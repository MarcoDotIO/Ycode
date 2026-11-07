import Foundation
import Synchronization

// Importance carried until the request is answered (`YCODE_REPLY_IMPORTANCE`;
// `specs/simulator/scheduling-policy.md` §4.11, `boot-profile.md` §22).
//
// xnu (level 1, `osfmk/ipc/ipc_importance.c`): a receiver that asks for the
// message's voucher (`MACH_RCV_VOUCHER`, as libdispatch does for every
// dispatch_mach channel, and so every XPC connection) gets the message's
// importance moved into that voucher. The receiving task stays boosted for
// as long as the voucher lives: libdispatch keeps it with the received
// message and with every work item made while it is adopted, so the boost
// outlives the receiving thread's servicing episode and lasts until the
// request has been handled. Ycode has no voucher objects (`host_create_mach_voucher`
// answers 0); §4.3 ends a received boost with the servicing episode, which
// for an XPC daemon is before the request is served (the listener's thread
// hands the message to a queue and returns to the workqueue).
//
// Ycode's proxy for the voucher's life: a request that carries importance
// and a send-once reply right. When a thread of an importance receiver takes
// it, the boost is tied to that reply right, in the space that received it,
// instead of to the thread: it ends when the right leaves that space (the
// reply is sent with it, it is deallocated or moved on, or the space ends),
// when the reply port dies, or when the process ends. Port-lock (G) state,
// as the rest of the importance bookkeeping (`mach-ipc-locking.md` §4.5).

/// One boost held for a request until its reply right leaves `holder` (G).
final class ReplyBoost {
    weak var holder: MachIPC?
    weak var process: DarwinProcess?
    let since: UInt64

    init(holder: MachIPC, process: DarwinProcess) {
        self.holder = holder
        self.process = process
        since = KernelClock.now()
    }
}

extension SchedPolicy {
    /// `YCODE_REPLY_IMPORTANCE` (with importance bookkeeping): a received
    /// importance message with a send-once reply right keeps its boost until
    /// the reply right leaves the receiving space (§4.11). `1` on, `0` off.
    nonisolated(unsafe) public static var replyImportanceEnabled = flag("YCODE_REPLY_IMPORTANCE", false)
    /// `YCODE_IMPORTANCE_TRACE=<program>[,<program>...]`: one line for each
    /// user message to a listed program (with its importance and reply), each
    /// request boost tied to a reply right and its end, and each change of a
    /// listed program between boosted and darwin-bg.
    public static let importanceTraced: Set<String> = {
        guard let v = env("YCODE_IMPORTANCE_TRACE") else { return [] }
        return Set(v.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
    }()
}

extension SchedStats {
    /// Request boosts tied to a reply right; ended by the reply (the right
    /// sent as a destination), by the right leaving otherwise (deallocated,
    /// moved, the space ended, the reply port died); their total and longest
    /// life.
    public static let replyBoosts = Atomic<UInt64>(0)
    public static let replyBoostsAnswered = Atomic<UInt64>(0)
    public static let replyBoostsDropped = Atomic<UInt64>(0)
    public static let replyBoostNanoseconds = Atomic<UInt64>(0)
    public static let replyBoostLongest = Atomic<UInt64>(0)

    /// Ended request boosts' time by program (diagnostics; a leaf lock).
    static let replyBoostByProgram = Mutex<[String: UInt64]>([:])

    static var replyImportanceReport: String {
        guard SchedPolicy.replyImportanceEnabled else { return "" }
        let top = replyBoostByProgram.withLock { $0 }.sorted { $0.value > $1.value }.prefix(8)
            .map { "\($0.key) \($0.value / 1_000_000)" }.joined(separator: ", ")
        let n = replyBoosts.load(ordering: .relaxed)
        let answered = replyBoostsAnswered.load(ordering: .relaxed), dropped = replyBoostsDropped.load(ordering: .relaxed)
        let ended = answered + dropped
        let mean = ended == 0 ? 0 : replyBoostNanoseconds.load(ordering: .relaxed) / ended / 1_000_000
        return "; request boosts \(n) (answered \(answered), dropped \(dropped), held \(n &- ended); "
            + "mean \(mean) ms, longest \(replyBoostLongest.load(ordering: .relaxed) / 1_000_000) ms; ms by program: \(top))"
    }
}

extension MachIPC {
    /// Ties one boost of `process` to the send-once right to `reply` that
    /// this space is receiving (§4.11). G held.
    func attachReplyBoost(_ reply: IPCPort, process: DarwinProcess, messageID: Int32) {
        reply.replyBoosts.append(ReplyBoost(holder: self, process: process))
        process.changeImportance(1)
        SchedStats.replyBoosts.wrappingAdd(1, ordering: .relaxed)
        if !SchedPolicy.importanceTraced.isEmpty, SchedPolicy.importanceTraced.contains(process.name) {
            traceImportance("\(process.name) pid \(process.pid): request \(messageID) boost held until its reply (boosts \(process.importanceBoosts))")
        }
    }

    /// A send-once right to `p` leaves this space (freed); `answered` when it
    /// was sent as a message's destination. Ends the first boost this space
    /// holds for it. G held.
    func replyRightLeft(_ p: IPCPort, answered: Bool) {
        guard let i = p.replyBoosts.firstIndex(where: { $0.holder === self }) else { return }
        endReplyBoost(p.replyBoosts.remove(at: i), answered: answered, on: p)
    }

    /// The reply port died: every boost tied to a right to it ends. G held.
    func dropReplyBoosts(_ p: IPCPort) {
        let all = p.replyBoosts
        p.replyBoosts = []
        for b in all { endReplyBoost(b, answered: false, on: p) }
    }

    private func endReplyBoost(_ b: ReplyBoost, answered: Bool, on p: IPCPort) {
        let life = KernelClock.now() &- b.since
        if answered {
            SchedStats.replyBoostsAnswered.wrappingAdd(1, ordering: .relaxed)
        } else {
            SchedStats.replyBoostsDropped.wrappingAdd(1, ordering: .relaxed)
        }
        SchedStats.replyBoostNanoseconds.wrappingAdd(life, ordering: .relaxed)
        var longest = SchedStats.replyBoostLongest.load(ordering: .relaxed)
        while life > longest {
            let (done, now) = SchedStats.replyBoostLongest.compareExchange(expected: longest, desired: life, ordering: .relaxed)
            if done { break }
            longest = now
        }
        guard let proc = b.process, !proc.isZombie else { return }
        let name = proc.name
        SchedStats.replyBoostByProgram.withLock { $0[name, default: 0] &+= life }
        proc.changeImportance(-1)
        if !SchedPolicy.importanceTraced.isEmpty, SchedPolicy.importanceTraced.contains(proc.name) {
            traceImportance("\(proc.name) pid \(proc.pid): request boost ended (\(answered ? "answered" : "right gone")) after "
                + "\(life / 1_000_000) ms (boosts \(proc.importanceBoosts))")
        }
    }

    /// A user message from this space to `p` (`YCODE_IMPORTANCE_TRACE`):
    /// one line when its receiver is traced. G held.
    func traceImportanceSend(_ m: KMessage, to p: IPCPort, donor: Bool) {
        guard let target = importanceTarget(p) ?? p.receiver?.kernel?.schedProcessCache,
              SchedPolicy.importanceTraced.contains(target.name) else { return }
        let sender = kernel?.schedProcessCache
        var reply = "none"
        if case .sendOnce = m.reply { reply = "send-once" } else if case .send = m.reply { reply = "send" }
        traceImportance("message \(m.id) from \(sender?.name ?? "?") (\(donor ? "donor" : "not a donor"), boosts \(sender?.importanceBoosts ?? 0)) "
            + "to \(target.name): importance \(m.importance ? "yes" : "no"), port \(p.importanceDonation ? "accepts" : "refuses"), "
            + "reply \(reply), \(target.name) boosts \(target.importanceBoosts)")
    }

    func traceImportance(_ text: String) {
        let at = Double(KernelClock.now() &- BackgroundBand.origin) / 1e9
        FileHandle.standardError.write(Data("ycode-simd: importance: \(text) at \(String(format: "%.2f", at)) s\n".utf8))
    }
}
