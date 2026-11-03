// The pairing transport relay (specs/simulator/device-pairing.md §7.2, P-6,
// P-7; Ycode's decisions in §10).
//
// Under Ycode each simulated device is its own set of VMs with its own Mach
// world, so the peer's `com.apple.IDSSimRPC.local` port cannot be handed to a
// guest directly. Each device's host registers a host port of its own as
// `com.apple.IDSSimRPC.remote.<peer>` in its guest (PairingHost, round W4);
// this relay carries what arrives there into the peer's guest:
//
//   near half (device A)                          far half (device B)
//   endpoint receive ── relay-request {seq} ──▶   send a new request to B's
//   keeps A's reply right                         IDSSimRPC.local (702) with a
//                                                 send-once reply port of its own
//   reply on A's right ◀── relay-reply {seq} ──   B's reply (1100, RetCode)
//
// Rules (the spec's §4 and §7):
//   - The out-of-line regions are copied byte for byte and delivered as
//     out-of-line regions; the inline body (NDR, the byte count) and the
//     message id are kept. Nothing is parsed.
//   - Order per direction: one endpoint thread sends the requests over the
//     link in arrival order; the far half sends them into its guest from one
//     serial queue in the same order. Several requests may be in flight: the
//     far half does not wait for one reply before sending the next request.
//   - Peer absence: when the link is down, the peer's local port cannot be
//     found, or the far send fails with a dead destination, the request is
//     answered with RetCode MACH_SEND_INVALID_DEST (0x10000003), the code a
//     sender sees when its peer is gone (§4.2). A request that gets no answer
//     within the timeout is answered with MACH_SEND_TIMED_OUT. A guest never
//     waits forever on the relay.
//   - The relay adds no delay of its own (P-7).
//   - Size (P-12, §12): no 16 MiB cap. A request (or reply) whose
//     out-of-line regions are larger than one chunk crosses as `relay-chunk`
//     frames of at most `chunkSize` bytes, then its `relay-request`
//     (`relay-reply`) frame with the region sizes in place of the regions.
//     The link is ordered, so the far half holds at most one partly
//     assembled message per direction; the bytes queued for delivery into
//     the guest are bounded by `queuedLimit` (the link's reader waits until
//     the guest has taken enough), so later requests wait behind a large one
//     as in the reference's ids_simd.
//
// Portable: it uses only the host task (MachHostTask) and a link given by its
// owner, so the unit tests run it with two DarwinSystems standing in for the
// two VMs.

import Foundation
import YcodeDarwinKernel

/// What a relay needs from its owner (the device's pairing host).
public protocol PairingRelayLink: AnyObject, Sendable {
    /// This device's UDID.
    var udid: String { get }
    /// The host task (ports, sends, receives).
    var host: MachHostTask { get }
    /// Sends a frame (a dictionary with a `type`) to the peer's host over the
    /// link. False when there is no link with `peer`.
    @discardableResult func sendToPeer(_ peer: String, frame: [String: Any]) -> Bool
    /// A send right (host-task name) to a name in this device's guest (702).
    func findInGuest(_ name: String) throws -> UInt32
}

public final class PairingTransportRelay: @unchecked Sendable {
    public struct Options: Sendable {
        /// A request with no answer in this time is answered with MACH_SEND_TIMED_OUT.
        public var requestTimeout: TimeInterval
        /// The far half retries a look-up of the guest's local port that
        /// fails (a service not loaded yet) for this long before it answers
        /// MACH_SEND_INVALID_DEST.
        public var lookupWait: TimeInterval
        /// The largest request (all out-of-line bytes plus the body) carried;
        /// a larger one is answered with MACH_SEND_TOO_LARGE. A sanity bound
        /// only (no WatchConnectivity limit is documented, §11.3): 1 GiB.
        public var maximumPayload: Int
        /// Out-of-line bytes per `relay-chunk` frame; a message whose regions
        /// fit in one chunk crosses in one frame as before.
        public var chunkSize: Int
        /// The most bytes of the peer's requests waiting for delivery into
        /// this guest; beyond it the link's reader waits (a memory bound).
        public var queuedLimit: Int
        /// The name of the guest's own transport port.
        public var localName: String
        public init(requestTimeout: TimeInterval = 60, lookupWait: TimeInterval = 20, maximumPayload: Int = 1 << 30,
                    chunkSize: Int = 4 << 20, queuedLimit: Int = 64 << 20,
                    localName: String = "com.apple.IDSSimRPC.local") {
            self.requestTimeout = requestTimeout
            self.lookupWait = lookupWait
            self.maximumPayload = maximumPayload
            self.chunkSize = max(1, chunkSize)
            self.queuedLimit = max(1, queuedLimit)
            self.localName = localName
        }

        /// The options from the environment: `YCODE_PAIRING_RELAY_TIMEOUT_S`,
        /// `YCODE_PAIRING_RELAY_LOOKUP_S`, `YCODE_PAIRING_RELAY_MAX_MB`,
        /// `YCODE_PAIRING_RELAY_CHUNK_KB`.
        public static func fromEnvironment(_ env: [String: String] = ProcessInfo.processInfo.environment) -> Options {
            var o = Options()
            if let s = env["YCODE_PAIRING_RELAY_TIMEOUT_S"], let v = Double(s), v > 0 { o.requestTimeout = v }
            if let s = env["YCODE_PAIRING_RELAY_LOOKUP_S"], let v = Double(s), v >= 0 { o.lookupWait = v }
            if let s = env["YCODE_PAIRING_RELAY_MAX_MB"], let v = Int(s), v > 0 { o.maximumPayload = v << 20 }
            if let s = env["YCODE_PAIRING_RELAY_CHUNK_KB"], let v = Int(s), v > 0 { o.chunkSize = v << 10 }
            return o
        }
    }

    /// Frame types on the link.
    public enum Frame {
        public static let request = "relay-request"
        public static let reply = "relay-reply"
        /// A piece of a large message's out-of-line bytes: {seq, generation,
        /// part: "request"|"reply", data}; the message's own frame follows
        /// with `oolSizes` in place of `ool`.
        public static let chunk = "relay-chunk"
    }

    /// Counters and times, per direction (`out`: this guest's requests to the
    /// peer; `in`: the peer's requests delivered into this guest).
    public struct Statistics: Sendable, Equatable {
        public var requestsOut = 0, bytesOut = 0, repliesOut = 0, failedOut = 0, timedOutOut = 0
        public var requestsIn = 0, bytesIn = 0, failedIn = 0
        public var largestOut = 0, largestIn = 0
        /// Messages that crossed in pieces, and the pieces (both directions of this half).
        public var chunkedOut = 0, chunksOut = 0
        /// Near half: from taking a request off the endpoint to replying on
        /// the guest's right (milliseconds), for answered requests.
        public var roundTripsMs: [Double] = []
        /// Far half: from the near half's send to the delivery into this
        /// guest (milliseconds; both halves read one host clock).
        public var oneWayMs: [Double] = []

        public func summary() -> String {
            func stats(_ v: [Double]) -> String {
                guard !v.isEmpty else { return "-" }
                let s = v.sorted()
                return String(format: "min %.2f, median %.2f, max %.2f ms", s.first!, s[s.count / 2], s.last!)
            }
            return "out \(requestsOut) requests (\(bytesOut) bytes, largest \(largestOut)), \(repliesOut) replies, "
                + "\(failedOut) failed, \(timedOutOut) timed out; round trip \(stats(roundTripsMs)); "
                + (chunkedOut > 0 ? "\(chunkedOut) sent in \(chunksOut) pieces; " : "")
                + "in \(requestsIn) requests (\(bytesIn) bytes, largest \(largestIn)), \(failedIn) failed; "
                + "relay one-way \(stats(oneWayMs))"
        }
    }

    public let options: Options
    public let log: (String) -> Void
    private let lock = NSLock()
    private var stats = Statistics()
    private static let keptSamples = 4096

    // Near half: per peer, the requests waiting for the peer's answer.
    private struct Outgoing {
        var replyPort: UInt32
        var replyType: UInt32
        var id: Int32
        var deadline: UInt64
        var started: UInt64
    }
    private var outgoing: [String: [Int: Outgoing]] = [:]
    private var nextSeq: [String: Int] = [:]
    private var linkGeneration: [String: Int] = [:]

    // Far half: per peer, the serial delivery queue and the guest's port;
    // the reply ports of requests in flight (in one port set).
    private struct Incoming {
        var peer: String
        var seq: Int
        /// The near half's link generation (echoed in the reply).
        var generation: Int
        var deadline: UInt64
    }
    private var deliverQueues: [String: DispatchQueue] = [:]
    /// Pieces of large messages being assembled, by "<peer> <part> <seq>".
    private var assembling: [String: Data] = [:]
    /// Bytes of the peer's requests queued for delivery into this guest.
    private var queuedBytes = 0
    private let queuedChanged = NSCondition()
    private var localPort: UInt32?
    private var incoming: [UInt32: Incoming] = [:]
    private var replySet: UInt32?
    private weak var farLink: PairingRelayLink?
    private var running = true
    private var threadsStarted = false

    public init(options: Options = Options(), log: @escaping (String) -> Void) {
        self.options = options
        self.log = log
    }

    public var statistics: Statistics { lock.withLock { stats } }

    /// Ends the relay's threads; requests in flight are answered as for a lost peer.
    public func stop(link: PairingRelayLink) {
        let peers = lock.withLock { () -> [String] in
            running = false
            return Array(Set(outgoing.keys).union(deliverQueues.keys))
        }
        for p in peers { linkChanged(peer: p, up: false, link: link) }
        queuedChanged.lock()
        queuedChanged.broadcast()
        queuedChanged.unlock()
        if let set = lock.withLock({ () -> UInt32? in defer { replySet = nil }; return replySet }) {
            try? link.host.destroyPort(set)
        }
    }

    private static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
    private func deadline() -> UInt64 { Self.now() &+ UInt64(options.requestTimeout * 1e9) }

    // MARK: Near half

    /// A message taken off this guest's `remote.<peer>` endpoint. The relay
    /// owns its rights: it is forwarded, answered, or discarded.
    public func endpoint(peer rawPeer: String, received m: MachHostReceivedMessage, link: PairingRelayLink) {
        let peer = rawPeer.uppercased()
        let host = link.host
        startThreads(link)
        // Only out-of-line regions cross the link; a message carrying rights
        // (none is expected, §4.3) cannot be relayed.
        var regions: [Data] = []
        var carriesRights = false
        for d in m.descriptors {
            switch d {
            case let .ool(data, _, _): regions.append(Data(data))
            default: carriesRights = true
            }
        }
        let size = regions.reduce(m.body.count) { $0 + $1.count }
        let wantsReply = MachPortName.isValid(m.replyPort)
        if carriesRights {
            log("pairing relay: request id \(m.id) for \(peer) carries port rights; not relayed")
            fail(m, code: MachMsgReturn.sendInvalidRight, host: host)
            return
        }
        if size > options.maximumPayload {
            log("pairing relay: request id \(m.id) for \(peer) is \(size) bytes (at most \(options.maximumPayload)); not relayed")
            fail(m, code: MachMsgReturn.sendTooLarge, host: host)
            return
        }
        let started = Self.now()
        let (seq, generation, n) = lock.withLock { () -> (Int, Int, Int) in
            let s = (nextSeq[peer] ?? 0) + 1
            nextSeq[peer] = s
            if wantsReply {
                outgoing[peer, default: [:]][s] = Outgoing(replyPort: m.replyPort, replyType: m.replyType, id: m.id,
                                                           deadline: deadline(), started: started)
            }
            stats.requestsOut += 1
            stats.bytesOut += size
            stats.largestOut = max(stats.largestOut, size)
            return (s, linkGeneration[peer] ?? 0, stats.requestsOut)
        }
        let frame: [String: Any] = ["type": Frame.request, "seq": seq, "generation": generation, "id": Int(m.id),
                                    "body": Data(m.body), "reply": wantsReply]
        if n <= 3 || n.isMultiple(of: 100) || size > options.chunkSize {
            log("pairing relay: request \(n) to \(peer): id \(m.id), \(size) bytes"
                + (regions.reduce(0) { $0 + $1.count } > options.chunkSize ? " (in pieces)" : ""))
        }
        guard sendMessage(to: peer, frame: frame, regions: regions, part: "request", seq: seq, generation: generation,
                          stamp: true, link: link) else {
            // No link: the peer is gone (its endpoint here is about to die too).
            answerOutgoing(peer: peer, seq: seq, code: MachMsgReturn.sendInvalidDest, link: link)
            if !wantsReply { lock.withLock { stats.failedOut += 1 } }
            return
        }
    }

    // MARK: Pieces (P-12)

    /// Sends a request or reply frame with its out-of-line regions: inline
    /// (`ool`) when they fit in one chunk, else as `relay-chunk` frames
    /// followed by the frame with `oolSizes`. `stamp` adds `sent` (the host
    /// clock) just before the message's own frame. False when the link is gone.
    private func sendMessage(to peer: String, frame base: [String: Any], regions: [Data], part: String, seq: Int,
                             generation: Int, stamp: Bool, link: PairingRelayLink) -> Bool {
        var frame = base
        let total = regions.reduce(0) { $0 + $1.count }
        if total <= options.chunkSize {
            frame["ool"] = regions
        } else {
            var pieces = 0
            for r in regions {
                var off = r.startIndex
                while off < r.endIndex {
                    let end = min(off + options.chunkSize, r.endIndex)
                    let piece = r.subdata(in: off..<end)
                    guard link.sendToPeer(peer, frame: ["type": Frame.chunk, "seq": seq, "generation": generation, "part": part,
                                                        "data": piece]) else { return false }
                    pieces += 1
                    off = end
                }
            }
            frame["oolSizes"] = regions.map { $0.count }
            lock.withLock {
                stats.chunkedOut += 1
                stats.chunksOut += pieces
            }
        }
        if stamp { frame["sent"] = NSNumber(value: Self.now()) }
        return link.sendToPeer(peer, frame: frame)
    }

    private static func assemblyKey(_ peer: String, _ part: String, _ seq: Int, _ generation: Int) -> String {
        "\(peer) \(part) \(seq) \(generation)"
    }

    /// A `relay-chunk` frame: appended to its message's bytes.
    private func receivedChunk(peer: String, frame f: [String: Any]) {
        guard let seq = (f["seq"] as? NSNumber)?.intValue, let part = f["part"] as? String, let data = f["data"] as? Data else { return }
        let generation = (f["generation"] as? NSNumber)?.intValue ?? 0
        let key = Self.assemblyKey(peer, part, seq, generation)
        lock.withLock {
            if assembling[key] == nil { assembling[key] = Data() }
            assembling[key]!.append(data)
        }
    }

    /// The out-of-line regions of a request or reply frame: `ool`, or the
    /// assembled pieces split by `oolSizes`. Nil when pieces are missing.
    private func regions(of f: [String: Any], peer: String, part: String, seq: Int, generation: Int) -> [Data]? {
        guard let sizes = f["oolSizes"] as? [NSNumber] else { return (f["ool"] as? [Data]) ?? [] }
        let bytes = lock.withLock { assembling.removeValue(forKey: Self.assemblyKey(peer, part, seq, generation)) } ?? Data()
        let want = sizes.reduce(0) { $0 + $1.intValue }
        guard bytes.count == want else {
            log("pairing relay: \(part) \(seq) from \(peer): \(bytes.count) bytes in pieces, \(want) expected; dropped")
            return nil
        }
        var out: [Data] = []
        var off = bytes.startIndex
        for n in sizes.map(\.intValue) {
            out.append(bytes.subdata(in: off..<(off + n)))
            off += n
        }
        return out
    }

    /// Answers a request this half will not forward: a MIG error reply with
    /// `code` when it has a reply right, else its rights are dropped.
    private func fail(_ m: MachHostReceivedMessage, code: UInt32, host: MachHostTask) {
        lock.withLock { stats.failedOut += 1 }
        for d in m.descriptors {
            switch d {
            case let .port(name, _), let .guardedPort(name, _, _): try? host.deallocate(name)
            case let .oolPorts(names, _): for x in names { try? host.deallocate(x) }
            case .ool: break
            }
        }
        guard MachPortName.isValid(m.replyPort) else { return }
        sendErrorReply(port: m.replyPort, type: m.replyType, requestID: m.id, code: code, host: host)
    }

    /// The MIG error reply: `id` + 100, NDR, RetCode.
    private func sendErrorReply(port: UInt32, type: UInt32, requestID: Int32, code: UInt32, host: MachHostTask) {
        let body = Self.ndr + Self.le32(code)
        do {
            try host.send(MachHostOutgoingMessage(remotePort: port, remoteDisposition: type, id: requestID &+ 100, body: body),
                          timeout: 0)
        } catch {
            try? host.deallocate(port)
        }
    }

    /// Answers the outgoing request `seq` of `peer` with an error code (the
    /// peer is gone, or no answer came in time).
    private func answerOutgoing(peer: String, seq: Int, code: UInt32, link: PairingRelayLink) {
        guard let o = lock.withLock({ () -> Outgoing? in
            let o = outgoing[peer]?.removeValue(forKey: seq)
            if o != nil {
                stats.failedOut += 1
                if code == MachMsgReturn.sendTimedOut { stats.timedOutOut += 1 }
            }
            return o
        }) else { return }
        sendErrorReply(port: o.replyPort, type: o.replyType, requestID: o.id, code: code, host: link.host)
    }

    /// The peer's answer to one of this guest's requests.
    private func receivedReply(peer: String, frame f: [String: Any], link: PairingRelayLink) {
        guard let seq = (f["seq"] as? NSNumber)?.intValue else { return }
        let generation = (f["generation"] as? NSNumber)?.intValue ?? 0
        let code = UInt32(truncatingIfNeeded: (f["code"] as? NSNumber)?.int64Value ?? 0)
        guard let o = lock.withLock({ () -> Outgoing? in
            guard generation == (linkGeneration[peer] ?? 0) else { return nil }
            return outgoing[peer]?.removeValue(forKey: seq)
        }) else { return }
        let host = link.host
        if code != 0 {
            lock.withLock {
                _ = assembling.removeValue(forKey: Self.assemblyKey(peer, "reply", seq, generation))
                stats.failedOut += 1
                if code == MachMsgReturn.sendTimedOut { stats.timedOutOut += 1 }
            }
            sendErrorReply(port: o.replyPort, type: o.replyType, requestID: o.id, code: code, host: host)
            return
        }
        let id = Int32(truncatingIfNeeded: (f["id"] as? NSNumber)?.intValue ?? Int(o.id &+ 100))
        let body = [UInt8]((f["body"] as? Data) ?? Data())
        guard let regions = regions(of: f, peer: peer, part: "reply", seq: seq, generation: generation) else {
            lock.withLock { stats.failedOut += 1 }
            sendErrorReply(port: o.replyPort, type: o.replyType, requestID: o.id, code: MachMsgReturn.sendTooLarge, host: host)
            return
        }
        do {
            try host.send(MachHostOutgoingMessage(remotePort: o.replyPort, remoteDisposition: o.replyType, id: id,
                                                  descriptors: regions.map { .ool(data: [UInt8]($0), copy: 1) }, body: body),
                          timeout: 0)
        } catch {
            // The guest's reply right is gone (its sender ended): nothing to answer.
            try? host.deallocate(o.replyPort)
        }
        let ms = Double(Self.now() &- o.started) / 1e6
        lock.withLock {
            stats.repliesOut += 1
            if stats.roundTripsMs.count < Self.keptSamples { stats.roundTripsMs.append(ms) }
        }
    }

    // MARK: Far half

    /// A request of the peer's guest for this guest.
    private func receivedRequest(peer: String, frame f: [String: Any], link: PairingRelayLink) {
        guard let seq = (f["seq"] as? NSNumber)?.intValue else { return }
        let generation = (f["generation"] as? NSNumber)?.intValue ?? 0
        let id = Int32(truncatingIfNeeded: (f["id"] as? NSNumber)?.intValue ?? 0)
        let body = [UInt8]((f["body"] as? Data) ?? Data())
        let wantsReply = (f["reply"] as? Bool) ?? true
        let sent = (f["sent"] as? NSNumber)?.uint64Value
        startThreads(link)
        guard let regions = regions(of: f, peer: peer, part: "request", seq: seq, generation: generation) else {
            if wantsReply { answerPeer(peer, seq: seq, generation: generation, code: MachMsgReturn.sendTooLarge, link: link) }
            return
        }
        // The memory bound: wait while the guest has not taken enough of
        // what is queued (one message larger than the bound still goes alone).
        let size = regions.reduce(body.count) { $0 + $1.count }
        let waitUntil = Date().addingTimeInterval(options.requestTimeout)
        queuedChanged.lock()
        while queuedBytes > 0, queuedBytes + size > options.queuedLimit, lock.withLock({ running }), Date() < waitUntil {
            _ = queuedChanged.wait(until: min(waitUntil, Date().addingTimeInterval(0.25)))
        }
        queuedBytes += size
        queuedChanged.unlock()
        let (queue, own) = lock.withLock { () -> (DispatchQueue, Int) in
            let own = linkGeneration[peer] ?? 0
            if let q = deliverQueues[peer] { return (q, own) }
            let q = DispatchQueue(label: "ycode.pairing.relay.deliver.\(peer.prefix(8))")
            deliverQueues[peer] = q
            return (q, own)
        }
        let deadline = deadline()
        queue.async { [self] in
            defer {
                queuedChanged.lock()
                queuedBytes -= size
                queuedChanged.broadcast()
                queuedChanged.unlock()
            }
            deliver(peer: peer, seq: seq, generation: generation, ownGeneration: own, id: id, body: body, regions: regions,
                    wantsReply: wantsReply, sent: sent, deadline: deadline, link: link)
        }
    }

    private func answerPeer(_ peer: String, seq: Int, generation: Int, code: UInt32, link: PairingRelayLink) {
        lock.withLock { stats.failedIn += 1 }
        link.sendToPeer(peer, frame: ["type": Frame.reply, "seq": seq, "generation": generation, "code": NSNumber(value: code)])
    }

    /// The guest's local port: the cached right, else a 702 look-up retried
    /// until `until` (the service may not be loaded yet).
    private func guestPort(link: PairingRelayLink, until: UInt64, stillWanted: () -> Bool) -> UInt32? {
        if let p = lock.withLock({ localPort }) { return p }
        var said = false
        while true {
            do {
                let p = try link.findInGuest(options.localName)
                lock.withLock { localPort = p }
                if said { log("pairing relay: found \(options.localName) in this guest") }
                return p
            } catch {
                if !said { log("pairing relay: \(options.localName) not found in this guest (\(error)); retrying") }
                said = true
            }
            if Self.now() >= until || !stillWanted() { return nil }
            Thread.sleep(forTimeInterval: 0.25)
        }
    }

    private func forgetGuestPort(_ p: UInt32, host: MachHostTask) {
        let drop = lock.withLock { () -> Bool in
            guard localPort == p else { return false }
            localPort = nil
            return true
        }
        if drop { try? host.deallocate(p) }
    }

    /// Delivers one request of the peer into this guest. `generation` is the
    /// near half's (echoed in the answer); `ownGeneration` this half's link
    /// generation when the request came (a request of a link that has gone
    /// is not delivered).
    private func deliver(peer: String, seq: Int, generation: Int, ownGeneration: Int, id: Int32, body: [UInt8], regions: [Data],
                         wantsReply: Bool, sent: UInt64?, deadline: UInt64, link: PairingRelayLink) {
        let host = link.host
        let current = { [self] in lock.withLock { running && (linkGeneration[peer] ?? 0) == ownGeneration } }
        guard current() else { return }
        let size = regions.reduce(body.count) { $0 + $1.count }
        let lookupUntil = min(deadline, Self.now() &+ UInt64(options.lookupWait * 1e9))
        var attempts = 0
        while true {
            attempts += 1
            guard let target = guestPort(link: link, until: lookupUntil, stillWanted: current) else {
                if wantsReply { answerPeer(peer, seq: seq, generation: generation, code: MachMsgReturn.sendInvalidDest, link: link) }
                return
            }
            var reply: UInt32 = 0
            if wantsReply {
                do {
                    reply = try host.makePort()
                    guard let set = lock.withLock({ replySet }) else { throw MachHostError(MachKern.failure) }
                    try host.addMember(reply, to: set)
                } catch {
                    if MachPortName.isValid(reply) { try? host.destroyPort(reply) }
                    answerPeer(peer, seq: seq, generation: generation, code: MachMsgReturn.sendNoBuffer, link: link)
                    return
                }
                lock.withLock { incoming[reply] = Incoming(peer: peer, seq: seq, generation: generation, deadline: deadline) }
            }
            let left = deadline > Self.now() ? deadline - Self.now() : 0
            do {
                try host.send(MachHostOutgoingMessage(
                    remotePort: target, remoteDisposition: MachMsgType.copySend,
                    localPort: reply, localDisposition: wantsReply ? MachMsgType.makeSendOnce : 0, id: id,
                    descriptors: regions.map { .ool(data: [UInt8]($0), copy: 1) }, body: body), timeout: left)
            } catch let e as MachHostError {
                if wantsReply {
                    lock.withLock { _ = incoming.removeValue(forKey: reply) }
                    try? host.destroyPort(reply)
                }
                if e.code == MachMsgReturn.sendInvalidDest && attempts == 1 {
                    // The cached right is dead (the service was reloaded): look it up again once.
                    forgetGuestPort(target, host: host)
                    continue
                }
                if e.code == MachMsgReturn.sendInvalidDest { forgetGuestPort(target, host: host) }
                log("pairing relay: delivery of \(peer)'s request id \(id) failed: \(e)")
                if wantsReply { answerPeer(peer, seq: seq, generation: generation, code: e.code, link: link) }
                return
            } catch {
                if wantsReply {
                    lock.withLock { _ = incoming.removeValue(forKey: reply) }
                    try? host.destroyPort(reply)
                    answerPeer(peer, seq: seq, generation: generation, code: MachKern.failure, link: link)
                }
                return
            }
            let n = lock.withLock { () -> Int in
                stats.requestsIn += 1
                stats.bytesIn += size
                stats.largestIn = max(stats.largestIn, size)
                if let sent, stats.oneWayMs.count < Self.keptSamples {
                    stats.oneWayMs.append(Double(Self.now() &- sent) / 1e6)
                }
                return stats.requestsIn
            }
            if n <= 3 || n.isMultiple(of: 100) {
                log("pairing relay: request \(n) from \(peer) delivered: id \(id), \(size) bytes")
            }
            return
        }
    }

    /// The far half's reply receiver and the timeout sweep.
    private func startThreads(_ link: PairingRelayLink) {
        let start = lock.withLock { () -> Bool in
            guard !threadsStarted, running else { return false }
            threadsStarted = true
            farLink = link
            return true
        }
        guard start else { return }
        let host = link.host
        do {
            let set = try host.makePortSet()
            lock.withLock { replySet = set }
        } catch {
            log("pairing relay: no port set for replies: \(error)")
        }
        let receiver = Thread { [weak self] in self?.receiveReplies(host: host) }
        receiver.name = "ycode-pair-relay-replies"
        receiver.start()
        let sweeper = Thread { [weak self] in
            while let self, lock.withLock({ running }) {
                sweep()
                Thread.sleep(forTimeInterval: 0.25)
            }
        }
        sweeper.name = "ycode-pair-relay-timeouts"
        sweeper.start()
    }

    private func receiveReplies(host: MachHostTask) {
        while true {
            guard let set = lock.withLock({ running ? replySet : nil }) else { return }
            let m: MachHostReceivedMessage
            do {
                m = try host.receive(on: set, timeout: 250_000_000, tracked: true)
            } catch let e as MachHostError where e == .timedOut || e == .interrupted {
                continue
            } catch {
                return
            }
            defer { host.finishedMessage() }
            let (entry, link) = lock.withLock { (incoming.removeValue(forKey: m.localPort), farLink) }
            try? host.destroyPort(m.localPort)
            guard let entry, let link else {
                host.discard(m)
                continue
            }
            // Only out-of-line regions cross; rights in a reply (none expected) are dropped.
            var regions: [Data] = []
            for d in m.descriptors {
                switch d {
                case let .ool(data, _, _): regions.append(Data(data))
                case let .port(name, _), let .guardedPort(name, _, _): try? host.deallocate(name)
                case let .oolPorts(names, _): for x in names { try? host.deallocate(x) }
                }
            }
            if MachPortName.isValid(m.replyPort) { try? host.deallocate(m.replyPort) }
            // A send-once notification (the guest dropped the reply right):
            // the request was taken but not answered.
            // The near half answers MIG_SERVER_DIED, what a MIG client returns then.
            if m.isFromKernel && m.id == MachNotify.sendOnce {
                answerPeer(entry.peer, seq: entry.seq, generation: entry.generation, code: MachKern.migServerDied, link: link)
                continue
            }
            _ = sendMessage(to: entry.peer, frame: ["type": Frame.reply, "seq": entry.seq, "generation": entry.generation,
                                                    "code": NSNumber(value: 0), "id": Int(m.id), "body": Data(m.body)],
                            regions: regions, part: "reply", seq: entry.seq, generation: entry.generation, stamp: false, link: link)
        }
    }

    /// Answers what has waited past its deadline, on both halves.
    private func sweep() {
        let now = Self.now()
        let (late, lateIn, link, host) = lock.withLock { () -> ([(String, Int)], [(UInt32, Incoming)], PairingRelayLink?, MachHostTask?) in
            var out: [(String, Int)] = []
            for (p, list) in outgoing {
                for (s, o) in list where o.deadline <= now { out.append((p, s)) }
            }
            let inc = incoming.filter { $0.value.deadline <= now }.map { ($0.key, $0.value) }
            for (k, _) in inc { incoming.removeValue(forKey: k) }
            return (out, inc, farLink, farLink?.host)
        }
        guard let link, let host else { return }
        for (p, s) in late {
            log("pairing relay: request \(s) to \(p) got no answer in \(Int(options.requestTimeout)) s")
            answerOutgoing(peer: p, seq: s, code: MachMsgReturn.sendTimedOut, link: link)
        }
        for (port, e) in lateIn {
            try? host.destroyPort(port)
            answerPeer(e.peer, seq: e.seq, generation: e.generation, code: MachMsgReturn.sendTimedOut, link: link)
        }
    }

    // MARK: Link

    /// A link frame of the relay (`relay-request`, `relay-reply`); false for
    /// any other type.
    @discardableResult
    public func link(peer rawPeer: String, received frame: [String: Any], link: PairingRelayLink) -> Bool {
        let peer = rawPeer.uppercased()
        switch frame["type"] as? String {
        case Frame.request: receivedRequest(peer: peer, frame: frame, link: link)
        case Frame.reply: receivedReply(peer: peer, frame: frame, link: link)
        case Frame.chunk: receivedChunk(peer: peer, frame: frame)
        default: return false
        }
        return true
    }

    /// The link with `peer` came up or went down. Down: this guest's requests
    /// waiting for the peer are answered MACH_SEND_INVALID_DEST, and the
    /// peer's requests in flight here are abandoned (their reply ports go).
    /// Each link gets a new generation, so a late frame of an old link is ignored.
    public func linkChanged(peer rawPeer: String, up: Bool, link: PairingRelayLink) {
        let peer = rawPeer.uppercased()
        let (waiting, abandoned) = lock.withLock { () -> ([Int], [UInt32]) in
            linkGeneration[peer] = (linkGeneration[peer] ?? 0) + 1
            let w = Array((outgoing[peer] ?? [:]).keys).sorted()
            let a = incoming.filter { $0.value.peer == peer }.map(\.key)
            for k in a { incoming.removeValue(forKey: k) }
            for k in assembling.keys where k.hasPrefix(peer + " ") { assembling.removeValue(forKey: k) }
            return (w, a)
        }
        for p in abandoned { try? link.host.destroyPort(p) }
        for s in waiting { answerOutgoing(peer: peer, seq: s, code: MachMsgReturn.sendInvalidDest, link: link) }
        let st = lock.withLock { stats }
        if !up || st.requestsOut + st.requestsIn > 0 {
            log("pairing relay: link with \(peer) \(up ? "up" : "down")"
                + (waiting.isEmpty ? "" : "; \(waiting.count) requests answered MACH_SEND_INVALID_DEST")
                + (abandoned.isEmpty ? "" : "; \(abandoned.count) deliveries abandoned") + "; " + st.summary())
        }
    }

    // MARK: Bytes

    static let ndr: [UInt8] = [0, 0, 0, 0, 1, 0, 0, 0]
    static func le32(_ v: UInt32) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 24)] }
}
