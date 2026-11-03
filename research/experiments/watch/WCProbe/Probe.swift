// WCProbe: Ycode research probe (original Ycode code, no Apple code).
// One source, built twice: for the iOS simulator (-D PHONE) and for the
// watchOS simulator (-D WATCH). Both sides activate WCSession, log the
// session state, and exchange messages so that pairing behaviour and the
// transport's latency can be observed from the unified log:
//   log show --predicate 'eventMessage BEGINSWITH "WCPROBE"'
// Every line: WCPROBE side=<phone|watch> ev=<event> key=value ...
import SwiftUI
import WatchConnectivity
import os

#if PHONE
let side = "phone"
#else
let side = "watch"
#endif

func now() -> Double { Date().timeIntervalSince1970 }

func plog(_ ev: String, _ kv: [String: Any] = [:]) {
    let rest = kv.keys.sorted().map { "\($0)=\(kv[$0]!)" }.joined(separator: " ")
    NSLog("WCPROBE side=%@ ev=%@ %@", side, ev, rest)
}

final class Probe: NSObject, WCSessionDelegate {
    static let shared = Probe()
    var seq = 0
    var timer: Timer?

    func start() {
        plog("launch", ["supported": WCSession.isSupported()])
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func state(_ ev: String) {
        let s = WCSession.default
        var kv: [String: Any] = ["activation": s.activationState.rawValue, "reachable": s.isReachable,
                                 "hasContentPending": s.hasContentPending,
                                 "ctxKeys": s.receivedApplicationContext.count,
                                 "outstandingUserInfo": s.outstandingUserInfoTransfers.count]
        #if PHONE
        kv["paired"] = s.isPaired
        kv["watchAppInstalled"] = s.isWatchAppInstalled
        kv["complicationEnabled"] = s.isComplicationEnabled
        kv["watchDir"] = s.watchDirectoryURL?.path ?? "nil"
        #else
        kv["companionAppInstalled"] = s.isCompanionAppInstalled
        #endif
        plog(ev, kv)
    }

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        plog("activated", ["state": activationState.rawValue, "error": error.map { "\($0)" } ?? "nil"])
        state("state")
        DispatchQueue.main.async { self.kick() }
    }

    func kick() {
        let t = now()
        do {
            try WCSession.default.updateApplicationContext(["from": side, "t": t])
            plog("ctxSent", ["t": t])
        } catch { plog("ctxError", ["error": "\(error)"]) }
        WCSession.default.transferUserInfo(["from": side, "t": t, "kind": "userInfo"])
        plog("userInfoQueued", ["t": t])
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in self.tick() }
    }

    func tick() {
        state("tick")
        guard WCSession.default.isReachable else { return }
        seq += 1
        let s = seq, t0 = now()
        WCSession.default.sendMessage(["from": side, "seq": s, "t": t0], replyHandler: { reply in
            let t1 = now()
            plog("reply", ["seq": s, "rttMs": Int((t1 - t0) * 1000),
                           "oneWayMs": Int(((reply["t"] as? Double ?? t1) - t0) * 1000)])
        }, errorHandler: { error in
            plog("sendError", ["seq": s, "error": "\(error)"])
        })
        if s % 5 == 0 {
            // A larger payload, to see whether size changes the latency.
            let blob = Data(repeating: 0x5A, count: 64 * 1024)
            let tb = now()
            WCSession.default.sendMessageData(blob, replyHandler: { r in
                plog("dataReply", ["bytes": blob.count, "rttMs": Int((now() - tb) * 1000), "replyBytes": r.count])
            }, errorHandler: { e in plog("dataError", ["error": "\(e)"]) })
        }
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        let t = now()
        plog("message", ["seq": message["seq"] ?? -1, "latencyMs": Int((t - (message["t"] as? Double ?? t)) * 1000)])
        replyHandler(["echo": message["seq"] ?? -1, "t": t, "from": side])
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        plog("messageNoReply", ["keys": message.count])
    }

    func session(_ session: WCSession, didReceiveMessageData messageData: Data, replyHandler: @escaping (Data) -> Void) {
        plog("messageData", ["bytes": messageData.count])
        replyHandler(Data(repeating: 0xA5, count: 16))
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        let t = now()
        plog("userInfo", ["from": userInfo["from"] ?? "?", "latencyMs": Int((t - (userInfo["t"] as? Double ?? t)) * 1000)])
    }

    func session(_ session: WCSession, didFinish userInfoTransfer: WCSessionUserInfoTransfer, error: Error?) {
        plog("userInfoFinished", ["error": error.map { "\($0)" } ?? "nil"])
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        let t = now()
        plog("context", ["from": applicationContext["from"] ?? "?", "latencyMs": Int((t - (applicationContext["t"] as? Double ?? t)) * 1000)])
    }

    func sessionReachabilityDidChange(_ session: WCSession) { state("reachabilityChanged") }

    #if PHONE
    func sessionDidBecomeInactive(_ session: WCSession) { plog("inactive") }
    func sessionDidDeactivate(_ session: WCSession) { plog("deactivated"); WCSession.default.activate() }
    func sessionWatchStateDidChange(_ session: WCSession) { state("watchStateChanged") }
    #else
    func sessionCompanionAppInstalledDidChange(_ session: WCSession) { state("companionChanged") }
    #endif
}

@main
struct WCProbeApp: App {
    init() { Probe.shared.start() }
    var body: some Scene {
        WindowGroup { Text("WCProbe \(side)") }
    }
}
