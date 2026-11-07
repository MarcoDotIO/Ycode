import Foundation
import Synchronization

// Pushes and importance through a port in transit (`YCODE_TRANSIT_PUSH`;
// `specs/simulator/scheduling-policy.md` §4.13, `boot-profile.md` §25).
//
// xnu (level 1; behaviour read from the open-source `osfmk/ipc/ipc_port.c`,
// the send turnstile's inheritor and the importance delta of a port, and
// `osfmk/ipc/ipc_importance.c`; nothing copied): while the receive right of a
// port travels inside a message queued on another port, the first port is
// *in transit* and its destination is the second. A synchronous request
// queued on the in-transit port pushes the destination port's send
// turnstile, so whoever will receive the carrying message is pushed; the
// importance of the messages queued on it goes the same way, down the chain
// of destinations, to the task that holds (or is bound to) the last port.
// An XPC client makes a connection by sending a receive right in its first
// message to the service's listener port and its requests to that port
// right away: until the server takes the first message, every request waits
// on a port in transit.
//
// Ycode before this: a port in transit had no target (`syncPushTarget`,
// `importanceTarget` look at the space holding the receive right), so such a
// request pushed nobody and its importance boosted nobody.
//
// Ycode with the switch (under the port lock G):
//
// - A port whose receive right is in transit (`transitHolder`: the port whose
//   queue holds the message that carries it) and that is no job's watch port
//   takes the target of that port, following such ports at most
//   `YCODE_SYNC_PUSH_DEPTH` hops: for the sync-wait push (§4.10, §4.12's
//   queued credit) and for importance (§4.3).
// - The credit moves when the right goes into transit (the carrying message
//   is queued) and when it lands in a space (copied out).
// - Not modelled: a change of the carrying port's own target (its receive
//   right moves) does not move the credit of the ports in transit in its
//   queue until their next enqueue, dequeue or copy-out.

extension SchedPolicy {
    /// `YCODE_TRANSIT_PUSH` (`1` on, default off until measured): requests and
    /// importance queued on a port in transit credit the target of the port
    /// whose queue carries it (§4.13).
    nonisolated(unsafe) public static var transitPushEnabled = flag("YCODE_TRANSIT_PUSH", false)
}

extension SchedStats {
    /// Credits (sync-wait or importance) moved to a target through a port in transit.
    public static let transitCredits = Atomic<UInt64>(0)

    static var transitPushReport: String {
        guard SchedPolicy.transitPushEnabled else { return "" }
        return "; transit credits \(transitCredits.load(ordering: .relaxed))"
    }
}

extension MachIPC {
    /// The port at the end of `p`'s chain of destinations while its receive
    /// right is in transit, or nil when `p` is not in transit (or the switch
    /// is off). G held.
    func transitDestination(_ p: IPCPort) -> IPCPort? {
        guard SchedPolicy.transitPushEnabled, p.receiver == nil, p.transitHolder != nil else { return nil }
        var q = p
        var hops = 0
        while q.receiver == nil, let h = q.transitHolder, h.active, h !== p, hops < max(SchedPolicy.syncPushDepth, 1) {
            q = h
            hops += 1
        }
        return q === p ? nil : q
    }

    /// The receive right of each port in `rights` went into transit or landed
    /// in a space: their credits move to their new targets. G held.
    func transitMoved(_ rights: [IPCPort]) {
        guard SchedPolicy.transitPushEnabled else { return }
        for r in rights where r.active && (r.syncPushCounts != 0 || r.importanceCount > 0) {
            let before = (r.syncPushImage, r.creditedProcess)
            rebalanceSyncPush(r)
            if r.importanceCount > 0 { rebalanceImportance(r) }
            if r.syncPushImage !== before.0 || r.creditedProcess !== before.1 {
                SchedStats.transitCredits.wrappingAdd(1, ordering: .relaxed)
            }
        }
    }
}

extension SchedPolicy {
    /// `YCODE_WATCH_PUSH` (`1` on, default off until measured): with the reply
    /// push alone (`YCODE_SYNC_PUSH` off), a spawn still binds the job's watch
    /// ports for the queued credit (§4.10: a request queued on a launchd
    /// service port before the job checks in pushes the job, xnu's task
    /// watchports), and an exec moves the old image's credits to the new one.
    /// Before, only `YCODE_SYNC_PUSH` bound them, so with the default reply
    /// push such a request pushed launchd_sim (§4.13, `boot-profile.md` §25).
    nonisolated(unsafe) public static var watchPushEnabled = flag("YCODE_WATCH_PUSH", false)
    /// True when spawns bind watch ports for the sync-wait credit.
    @inline(__always) static var watchPortCreditActive: Bool {
        syncPushActive || (watchPushEnabled && replyPushActive)
    }
}

extension MachIPC {
    /// `p`'s target changed (a spawn bound it as a watch port): the ports in
    /// transit in its queue follow (§4.13). G held.
    func transitRetarget(_ p: IPCPort) {
        guard SchedPolicy.transitPushEnabled else { return }
        for m in p.messages.all where !m.receiveRights.isEmpty { transitMoved(m.receiveRights) }
    }
}
