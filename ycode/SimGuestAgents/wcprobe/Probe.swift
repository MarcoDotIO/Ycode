// WCProbe: Ycode's own WatchConnectivity test app (device-pairing.md §10,
// watchos.md §7.2 round W5). One source for both sides: the iOS app and its
// embedded watch app. Written from Apple's public WatchConnectivity
// documentation (WCSession, WCSessionDelegate); no Apple sample was used.
//
// Each side activates the default session and logs, one line each (NSLog and
// <tmp>/wcprobe.log, prefix "WCPROBE <role> <unix time>"):
//   - its state: activation, isReachable; the phone isPaired and
//     isWatchAppInstalled; the watch isCompanionAppInstalled (every 5 s);
//   - after activation: an application context and a user-info transfer;
//   - while reachable, every 3 s: sendMessage with a reply (its round trip
//     and the one-way time the peer measured); after 5 replies a burst of 20
//     messages back to back and one 64 KiB sendMessageData with a reply;
//   - the phone, after the burst (round W3b, device-pairing.md §12): one
//     complication user info (transferCurrentComplicationUserInfo), then 30 s
//     later one 20 MiB transferFile (P-12: a request of the file's size);
//   - everything the peer sends.
// The run ends by itself after 15 minutes of pings.

import Foundation
import WatchConnectivity

final class Probe: NSObject, WCSessionDelegate, @unchecked Sendable {
    static let shared = Probe()

    #if os(watchOS)
    let role = "watch"
    #else
    let role = "phone"
    #endif
    private let lock = NSLock()
    private var file: FileHandle?
    private var seq = 0
    private var replies = 0
    private var burstDone = false
    private var started = Date()
    private let queue = DispatchQueue(label: "wcprobe")

    func log(_ text: String) {
        let line = String(format: "WCPROBE %@ %.3f %@", role, Date().timeIntervalSince1970, text)
        NSLog("%@", line)
        lock.withLock {
            if file == nil {
                let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("wcprobe.log")
                FileManager.default.createFile(atPath: url.path, contents: nil)
                file = try? FileHandle(forWritingTo: url)
                file?.seekToEndOfFile()
            }
            file?.write(Data((line + "\n").utf8))
        }
    }

    func start() {
        log("start pid \(ProcessInfo.processInfo.processIdentifier) tmp \(NSTemporaryDirectory())")
        guard WCSession.isSupported() else {
            log("WCSession not supported")
            return
        }
        let s = WCSession.default
        s.delegate = self
        s.activate()
        log("activate called")
        started = Date()
        queue.asyncAfter(deadline: .now() + 1) { self.tick(0) }
    }

    func state() -> String {
        let s = WCSession.default
        var out = "activation \(s.activationState.rawValue) reachable \(s.isReachable)"
        #if os(watchOS)
        out += " companionAppInstalled \(s.isCompanionAppInstalled)"
        #else
        out += " paired \(s.isPaired) watchAppInstalled \(s.isWatchAppInstalled) watchDirectory \(s.watchDirectoryURL?.path ?? "nil")"
        #endif
        return out
    }

    /// Once a second: the state every 5 s, a ping every 3 s while reachable.
    private func tick(_ n: Int) {
        guard Date().timeIntervalSince(started) < 900 else {
            log("done: \(replies) replies; " + state())
            return
        }
        if n % 5 == 0 { log("state " + state()) }
        let s = WCSession.default
        if n % 3 == 0, s.activationState == .activated {
            if s.isReachable {
                ping()
            } else if n % 30 == 0 {
                // Not reachable: one send to record the error the session gives.
                send(["probe": "unreachable", "t": Date().timeIntervalSince1970], tag: "unreachable-send")
            }
        }
        queue.asyncAfter(deadline: .now() + 1) { self.tick(n + 1) }
    }

    private func nextSeq() -> Int { lock.withLock { seq += 1; return seq } }

    private func ping() {
        let replied = lock.withLock { replies }
        let done = lock.withLock { burstDone }
        if replied >= 5 && !done {
            lock.withLock { burstDone = true }
            burst()
            return
        }
        send(["seq": nextSeq(), "t": Date().timeIntervalSince1970, "from": role], tag: "ping")
    }

    private func send(_ message: [String: Any], tag: String, done: (() -> Void)? = nil) {
        let t0 = Date()
        let seq = message["seq"] as? Int ?? 0
        WCSession.default.sendMessage(message, replyHandler: { reply in
            let rtt = Date().timeIntervalSince(t0) * 1000
            let oneWay = ((reply["recv"] as? Double) ?? 0) - ((message["t"] as? Double) ?? 0)
            self.lock.withLock { self.replies += 1 }
            self.log(String(format: "rtt %@ seq %d %.1f ms (peer received after %.1f ms)", tag, seq, rtt, oneWay * 1000))
            done?()
        }, errorHandler: { error in
            let e = error as NSError
            self.log(String(format: "send %@ seq %d failed after %.1f ms: %@ %ld %@", tag, seq,
                            Date().timeIntervalSince(t0) * 1000, e.domain, e.code, e.localizedDescription))
            done?()
        })
    }

    /// 20 messages back to back, then one 64 KiB message data with a reply.
    private func burst() {
        log("burst start")
        let t0 = Date()
        let group = DispatchGroup()
        for _ in 0..<20 {
            group.enter()
            send(["seq": nextSeq(), "t": Date().timeIntervalSince1970, "from": role, "burst": true], tag: "burst") { group.leave() }
        }
        group.notify(queue: queue) {
            self.log(String(format: "burst of 20 done in %.1f ms", Date().timeIntervalSince(t0) * 1000))
            var data = Data(count: 64 << 10)
            for i in stride(from: 0, to: data.count, by: 997) { data[i] = UInt8(truncatingIfNeeded: i) }
            let t1 = Date()
            WCSession.default.sendMessageData(data, replyHandler: { reply in
                self.log(String(format: "rtt data 65536 bytes %.1f ms (reply %d bytes)", Date().timeIntervalSince(t1) * 1000, reply.count))
            }, errorHandler: { error in
                let e = error as NSError
                self.log("send data failed: \(e.domain) \(e.code) \(e.localizedDescription)")
            })
            #if os(iOS)
            self.queue.asyncAfter(deadline: .now() + 10) { self.complicationAndFile() }
            #endif
        }
    }

    #if os(iOS)
    /// One complication user info, then a 20 MiB file 30 s later (phone → watch).
    private func complicationAndFile() {
        let s = WCSession.default
        let t = s.transferCurrentComplicationUserInfo(["from": role, "complication": true, "t": Date().timeIntervalSince1970])
        log("complication userInfo queued (transferring \(t.isTransferring)); remaining \(s.remainingComplicationUserInfoTransfers)")
        queue.asyncAfter(deadline: .now() + 30) {
            let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("wcprobe-20MiB.bin")
            var data = Data(count: 20 << 20)
            for i in stride(from: 0, to: data.count, by: 4093) { data[i] = UInt8(truncatingIfNeeded: i / 4093) }
            do {
                try data.write(to: url)
                let f = WCSession.default.transferFile(url, metadata: ["from": self.role, "bytes": data.count])
                self.fileStarted = Date()
                self.log("file transfer queued: \(data.count) bytes (transferring \(f.isTransferring))")
            } catch {
                self.log("file write failed: \(error)")
            }
        }
    }
    #endif

    private var fileStarted = Date()
    private var lastScrollLog = Date.distantPast
    private var pendingScroll: Double?

    /// The watch list's scroll offset (points), logged at most every 0.5 s;
    /// the last one of a burst is logged 0.5 s later.
    func scrolled(to y: Double) {
        let due = lock.withLock { () -> Bool in
            pendingScroll = y
            return Date().timeIntervalSince(lastScrollLog) >= 0.5
        }
        if due { flushScroll() } else {
            queue.asyncAfter(deadline: .now() + 0.5) { self.flushScroll() }
        }
    }

    private func flushScroll() {
        guard let y = lock.withLock({ () -> Double? in
            defer { pendingScroll = nil }
            if pendingScroll != nil { lastScrollLog = Date() }
            return pendingScroll
        }) else { return }
        log(String(format: "scroll offset %.1f", y))
    }

    private func afterActivation() {
        let s = WCSession.default
        do {
            try s.updateApplicationContext(["from": role, "t": Date().timeIntervalSince1970])
            log("applicationContext sent")
        } catch {
            let e = error as NSError
            log("applicationContext failed: \(e.domain) \(e.code) \(e.localizedDescription)")
        }
        let transfer = s.transferUserInfo(["from": role, "n": 1, "t": Date().timeIntervalSince1970])
        log("userInfo transfer queued (transferring \(transfer.isTransferring)); outstanding \(s.outstandingUserInfoTransfers.count)")
    }

    // MARK: WCSessionDelegate

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        log("activation completed \(activationState.rawValue) error \(error.map { "\($0)" } ?? "none"); " + state())
        if activationState == .activated { queue.async { self.afterActivation() } }
    }

    #if os(iOS)
    func sessionDidBecomeInactive(_ session: WCSession) { log("session inactive") }

    func sessionDidDeactivate(_ session: WCSession) {
        log("session deactivated; activating again")
        WCSession.default.activate()
    }

    func sessionWatchStateDidChange(_ session: WCSession) { log("watch state changed; " + state()) }
    #endif

    #if os(watchOS)
    func sessionCompanionAppInstalledDidChange(_ session: WCSession) { log("companion app installed changed; " + state()) }
    #endif

    #if os(watchOS)
    private var primaryActions = 0

    /// The list's primary-action button ran (a double tap, or a tap on it).
    func primaryAction() {
        let n = lock.withLock { primaryActions += 1; return primaryActions }
        log("primary action \(n) (hand gesture shortcut)")
    }
    #endif

    func sessionReachabilityDidChange(_ session: WCSession) { log("reachability changed; " + state()) }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        let now = Date().timeIntervalSince1970
        replyHandler(["recv": now, "from": role, "seq": message["seq"] ?? 0])
        let seq = message["seq"] as? Int ?? 0
        if seq <= 5 || seq % 10 == 0 || (message["probe"] as? String) != nil {
            log(String(format: "received message seq %d from %@ after %.1f ms", seq, message["from"] as? String ?? "?",
                       (now - ((message["t"] as? Double) ?? now)) * 1000))
        }
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        log("received message (no reply) \(message.keys.sorted())")
    }

    func session(_ session: WCSession, didReceiveMessageData messageData: Data, replyHandler: @escaping (Data) -> Void) {
        log("received message data \(messageData.count) bytes")
        replyHandler(Data(messageData.prefix(16)))
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        log("received applicationContext from \(applicationContext["from"] as? String ?? "?")")
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        log("received userInfo from \(userInfo["from"] as? String ?? "?") n \(userInfo["n"] as? Int ?? 0)"
            + ((userInfo["complication"] as? Bool) == true ? " (complication)" : ""))
    }

    func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        log(String(format: "file transfer finished after %.1f ms; error %@", Date().timeIntervalSince(fileStarted) * 1000,
                   error.map { "\($0)" } ?? "none"))
    }

    func session(_ session: WCSession, didReceive file: WCSessionFile) {
        let n = (try? FileManager.default.attributesOfItem(atPath: file.fileURL.path)[.size] as? Int) ?? -1
        log("received file \(file.fileURL.lastPathComponent) \(n) bytes metadata \(file.metadata ?? [:])")
    }

    func session(_ session: WCSession, didFinish userInfoTransfer: WCSessionUserInfoTransfer, error: Error?) {
        log("userInfo transfer finished; error \(error.map { "\($0)" } ?? "none")")
    }
}
