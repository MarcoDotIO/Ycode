// WCProbe2: Ycode research probe (original Ycode code, no Apple code), written
// from Apple's public WatchConnectivity documentation. One source, built for
// the iOS simulator (-D PHONE) and the watchOS simulator (-D WATCH).
//
// Each side activates the default WCSession and logs one line per event:
//   NSLog "WCP2 <side> <unix time> <event> key=value ..."
// and appends the same line to <data container>/Documents/wcp2.log.
//
// The launch arguments choose what the side sends once activated:
//   ui <n>            transferUserInfo n dictionaries
//   file <bytes>      transferFile of a new file of that size, with metadata
//   comp              (phone) transferCurrentComplicationUserInfo
//   ctx               updateApplicationContext
//   msg               one sendMessage with a reply (if reachable)
//   (none)            only activate and log what arrives
// Every 5 s: the session's state (activation, reachability, pending
// content, outstanding transfers; phone: isPaired, isWatchAppInstalled,
// isComplicationEnabled, watchDirectoryURL, remaining complication transfers).
// Received files are copied to Documents/received/ and listed.
import SwiftUI
import WatchConnectivity

#if PHONE
let side = "phone"
#else
let side = "watch"
#endif

let started = Date().timeIntervalSince1970
let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]

func plog(_ ev: String, _ kv: [String: Any] = [:]) {
    let rest = kv.keys.sorted().map { "\($0)=\(kv[$0]!)" }.joined(separator: " ")
    let line = String(format: "WCP2 %@ %.3f %@ %@", side, Date().timeIntervalSince1970, ev, rest)
    NSLog("%@", line)
    let url = docs.appendingPathComponent("wcp2.log")
    if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
    if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(Data((line + "\n").utf8)); try? h.close() }
}

final class Probe: NSObject, WCSessionDelegate {
    static let shared = Probe()
    var timer: Timer?
    var args: [String] = Array(CommandLine.arguments.dropFirst())

    func start() {
        plog("launch", ["supported": WCSession.isSupported(), "args": args.joined(separator: ","),
                        "appState": appStateString()])
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func appStateString() -> String {
        #if PHONE
        return "\(UIApplication.shared.applicationState.rawValue)"
        #else
        return "\(WKApplication.shared().applicationState.rawValue)"
        #endif
    }

    func state(_ ev: String) {
        let s = WCSession.default
        var kv: [String: Any] = ["activation": s.activationState.rawValue, "reachable": s.isReachable,
                                 "pending": s.hasContentPending,
                                 "ctxKeys": s.receivedApplicationContext.count,
                                 "outUserInfo": s.outstandingUserInfoTransfers.count,
                                 "outFiles": s.outstandingFileTransfers.count]
        #if PHONE
        kv["paired"] = s.isPaired
        kv["watchAppInstalled"] = s.isWatchAppInstalled
        kv["complicationEnabled"] = s.isComplicationEnabled
        kv["remainingComp"] = s.remainingComplicationUserInfoTransfers
        kv["watchDir"] = s.watchDirectoryURL?.path ?? "nil"
        #else
        kv["companionAppInstalled"] = s.isCompanionAppInstalled
        #endif
        plog(ev, kv)
    }

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        plog("activated", ["state": activationState.rawValue, "error": error.map { "\($0)" } ?? "nil"])
        state("state")
        DispatchQueue.main.async { self.act() }
    }

    func act() {
        let s = WCSession.default
        let t = Date().timeIntervalSince1970
        var i = 0
        while i < args.count {
            let a = args[i]; i += 1
            switch a {
            case "ui":
                let n = i < args.count ? Int(args[i]) ?? 1 : 1; i += 1
                for k in 0..<n {
                    let tr = s.transferUserInfo(["from": side, "t": t, "k": k, "kind": "userInfo"])
                    plog("userInfoQueued", ["k": k, "transferring": tr.isTransferring])
                }
            case "file":
                let n = i < args.count ? Int(args[i]) ?? 1024 : 1024; i += 1
                let url = docs.appendingPathComponent("out-\(n)-\(Int(t)).bin")
                FileManager.default.createFile(atPath: url.path, contents: Data(repeating: 0x5A, count: n))
                let tr = s.transferFile(url, metadata: ["from": side, "t": t, "bytes": n])
                plog("fileQueued", ["bytes": n, "transferring": tr.isTransferring, "path": url.lastPathComponent])
            case "comp":
                #if PHONE
                let tr = s.transferCurrentComplicationUserInfo(["from": side, "t": t, "kind": "complication"])
                plog("compQueued", ["isCurrentComplicationInfo": tr.isCurrentComplicationInfo,
                                    "remaining": s.remainingComplicationUserInfoTransfers])
                #endif
            case "ctx":
                do { try s.updateApplicationContext(["from": side, "t": t]); plog("ctxSent") }
                catch { plog("ctxError", ["error": "\(error)"]) }
            case "msg":
                if s.isReachable {
                    s.sendMessage(["from": side, "t": t], replyHandler: { r in
                        plog("reply", ["rttMs": Int((Date().timeIntervalSince1970 - t) * 1000)])
                    }, errorHandler: { e in plog("sendError", ["error": "\(e)"]) })
                } else { plog("msgSkipped", ["reachable": false]) }
            default: break
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { _ in self.state("tick") }
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        plog("message", ["from": message["from"] ?? "?"])
        replyHandler(["t": Date().timeIntervalSince1970])
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        let t = Date().timeIntervalSince1970
        plog("userInfo", ["from": userInfo["from"] ?? "?", "k": userInfo["k"] ?? "?", "kind": userInfo["kind"] ?? "?",
                          "ageMs": Int((t - (userInfo["t"] as? Double ?? t)) * 1000),
                          "sinceLaunchMs": Int((t - started) * 1000), "appState": appStateString()])
    }

    func session(_ session: WCSession, didFinish userInfoTransfer: WCSessionUserInfoTransfer, error: Error?) {
        var kv: [String: Any] = ["k": userInfoTransfer.userInfo["k"] ?? "?",
                                 "kind": userInfoTransfer.userInfo["kind"] ?? "?",
                                 "error": error.map { "\($0)" } ?? "nil"]
        #if PHONE
        kv["comp"] = userInfoTransfer.isCurrentComplicationInfo
        #endif
        plog("userInfoFinished", kv)
    }

    func session(_ session: WCSession, didReceive file: WCSessionFile) {
        let t = Date().timeIntervalSince1970
        let size = (try? FileManager.default.attributesOfItem(atPath: file.fileURL.path)[.size] as? Int) ?? -1
        let dir = docs.appendingPathComponent("received")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(file.fileURL.lastPathComponent)
        try? FileManager.default.removeItem(at: dest)
        let copied = (try? FileManager.default.copyItem(at: file.fileURL, to: dest)) != nil
        plog("file", ["path": file.fileURL.path, "bytes": size, "copied": copied,
                      "meta": (file.metadata ?? [:]).keys.sorted().joined(separator: ","),
                      "ageMs": Int((t - (file.metadata?["t"] as? Double ?? t)) * 1000),
                      "sinceLaunchMs": Int((t - started) * 1000), "appState": appStateString()])
    }

    func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        plog("fileFinished", ["path": fileTransfer.file.fileURL.lastPathComponent,
                              "error": error.map { "\($0)" } ?? "nil"])
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        plog("context", ["from": applicationContext["from"] ?? "?"])
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
struct WCProbe2App: App {
    init() { Probe.shared.start() }
    var body: some Scene {
        #if WATCH
        WindowGroup { Text("WCP2 \(side)") }
            .backgroundTask(.watchConnectivity) {
                plog("bgTaskWC", ["activation": WCSession.default.activationState.rawValue,
                                  "pending": WCSession.default.hasContentPending])
            }
        #else
        WindowGroup { Text("WCP2 \(side)") }
        #endif
    }
}
