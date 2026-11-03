import Foundation
import Testing
@testable import YcodeDarwinKernel
@testable import YcodeHostServices

/// PAIR-RELAY (device-pairing.md P-6, P-7, §10): the relay's two halves with
/// two DarwinSystems standing in for the two VMs. Device A's "ids_simd" sends
/// MIG 1000 requests to its endpoint (a host port of A); the near half sends
/// them over a test link; the far half delivers them to B's "IDSSimRPC.local"
/// (a host port of B served by a test thread) and carries B's reply back.
@Suite(.serialized) struct PairingTransportRelayTests {
    static let ndr: [UInt8] = [0, 0, 0, 0, 1, 0, 0, 0]

    /// One device: its system, its link, its relay.
    final class Device: PairingRelayLink, @unchecked Sendable {
        let udid: String
        let system = DarwinSystem()
        var host: MachHostTask { system.hostTask }
        let relay: PairingTransportRelay
        weak var other: Device?
        let lock = NSLock()
        var linked = true
        /// The guest's names for findInGuest (a receive right with a send right).
        var guestNames: [String: UInt32] = [:]
        var lookups = 0
        /// Frames in flight are delivered in order on one queue, as a socket's reader thread would.
        let reader: DispatchQueue
        var frames: [[String: Any]] = []

        init(_ udid: String, options: PairingTransportRelay.Options) {
            self.udid = udid
            relay = PairingTransportRelay(options: options, log: { _ in })
            reader = DispatchQueue(label: "test.link.\(udid)")
        }

        func sendToPeer(_ peer: String, frame: [String: Any]) -> Bool {
            guard lock.withLock({ linked }), let other, other.udid == peer else { return false }
            // The frame crosses as a binary property list, as on the rendezvous socket.
            guard let data = try? PropertyListSerialization.data(fromPropertyList: frame, format: .binary, options: 0),
                  let back = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
            else { Issue.record("frame not encodable: \(frame["type"] ?? "?")"); return false }
            lock.withLock { frames.append(back) }
            let box = FrameBox(back)
            other.reader.async { [udid] in
                guard other.lock.withLock({ other.linked }) else { return }
                other.relay.link(peer: udid, received: box.frame, link: other)
            }
            return true
        }

        func findInGuest(_ name: String) throws -> UInt32 {
            try lock.withLock {
                lookups += 1
                guard let p = guestNames[name] else { throw MachHostError(MachKern.invalidName) }
                try host.insertRight(p, from: p, disposition: MachMsgType.makeSend)
                return p
            }
        }

        func setLinked(_ on: Bool) { lock.withLock { linked = on } }
    }

    final class FrameBox: @unchecked Sendable {
        let frame: [String: Any]
        init(_ f: [String: Any]) { frame = f }
    }

    /// B's ids_simd: serves its local port, records each request, replies
    /// through `answer` (nil: hold the request until `release`).
    final class GuestServer: @unchecked Sendable {
        let host: MachHostTask
        let port: UInt32
        let lock = NSLock()
        var received: [MachHostReceivedMessage] = []
        var held: [MachHostReceivedMessage] = []
        let answer: @Sendable (MachHostReceivedMessage) -> UInt32?
        var stopped = false

        init(host: MachHostTask, answer: @escaping @Sendable (MachHostReceivedMessage) -> UInt32? = { _ in 0 }) throws {
            self.host = host
            self.answer = answer
            port = try host.makePort(sendRight: true, qlimit: 1024)
            Thread.detachNewThread { [self] in
                while !lock.withLock({ stopped }) {
                    guard let m = try? host.receive(on: port, timeout: 50_000_000) else { continue }
                    let code = lock.withLock { () -> UInt32? in
                        received.append(m)
                        return answer(m)
                    }
                    if let code { try? host.reply(to: m, id: 1100, body: ndr + le(code)) } else { lock.withLock { held.append(m) } }
                }
            }
        }

        func reply(_ m: MachHostReceivedMessage, code: UInt32) { try? host.reply(to: m, id: 1100, body: ndr + le(code)) }
        var count: Int { lock.withLock { received.count } }
        func stop() { lock.withLock { stopped = true } }
    }

    static func le(_ v: UInt32) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 24)] }
    static func word(_ b: [UInt8], _ at: Int) -> UInt32 {
        UInt32(b[at]) | UInt32(b[at + 1]) << 8 | UInt32(b[at + 2]) << 16 | UInt32(b[at + 3]) << 24
    }

    /// A and B linked both ways, B's local port served by `server`.
    func pair(_ options: PairingTransportRelay.Options = .init(requestTimeout: 10, lookupWait: 1),
              answer: @escaping @Sendable (MachHostReceivedMessage) -> UInt32? = { _ in 0 }) throws -> (Device, Device, GuestServer) {
        let a = Device("AAAAAAAA-0000-0000-0000-000000000001", options: options)
        let b = Device("BBBBBBBB-0000-0000-0000-000000000002", options: options)
        a.other = b
        b.other = a
        let server = try GuestServer(host: b.host, answer: answer)
        b.guestNames[options.localName] = server.port
        a.relay.linkChanged(peer: b.udid, up: true, link: a)
        b.relay.linkChanged(peer: a.udid, up: true, link: b)
        return (a, b, server)
    }

    func finish(_ a: Device, _ b: Device, _ s: GuestServer) {
        s.stop()
        a.relay.stop(link: a)
        b.relay.stop(link: b)
    }

    /// A's ids_simd sends one MIG 1000 (one OOL region, NDR, the byte count,
    /// a send-once reply right) to its endpoint; the endpoint's message goes
    /// to the relay. Returns the reply port (a receive right of A's host task).
    @discardableResult
    func send(_ a: Device, to peer: String, _ payload: [UInt8], id: Int32 = 1000, reply: Bool = true) throws -> UInt32 {
        let endpoint = try a.host.makePort(sendRight: true, qlimit: 64)
        defer { try? a.host.destroyPort(endpoint) }
        let replyPort = reply ? try a.host.makePort() : 0
        try a.host.send(MachHostOutgoingMessage(remotePort: endpoint, remoteDisposition: MachMsgType.copySend,
                                                localPort: replyPort, localDisposition: reply ? MachMsgType.makeSendOnce : 0,
                                                id: id, descriptors: [.ool(data: payload, copy: 1)],
                                                body: Self.ndr + Self.le(UInt32(payload.count))))
        let m = try a.host.receive(on: endpoint, timeout: 1_000_000_000)
        a.relay.endpoint(peer: peer, received: m, link: a)
        return replyPort
    }

    /// The RetCode of the reply on `port` (and its id).
    func replyCode(_ a: Device, _ port: UInt32, timeout: UInt64 = 10_000_000_000) throws -> (id: Int32, code: UInt32) {
        let m = try a.host.receive(on: port, timeout: timeout)
        try? a.host.destroyPort(port)
        #expect(!m.isComplex && m.body.count == 12 && Array(m.body.prefix(8)) == Self.ndr)
        return (m.id, m.body.count >= 12 ? Self.word(m.body, 8) : 0xFFFF_FFFF)
    }

    func waitUntil(_ seconds: Double = 10, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return condition()
    }

    @Test func aRequestCrossesWithItsRegionByteForByteAndTheReplyComesBack() throws {
        let (a, b, server) = try pair { m in m.body.count >= 12 ? 7 : 0 }
        defer { finish(a, b, server) }
        let payload = (0..<1985).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) }
        let r = try send(a, to: b.udid, payload)
        let (id, code) = try replyCode(a, r)
        #expect(id == 1100 && code == 7)  // B's own RetCode reaches A
        let m = try #require(server.lock.withLock { server.received.first })
        #expect(m.id == 1000 && m.isComplex && m.size == 56)
        #expect(m.descriptors.count == 1)
        guard case let .ool(data, _, _) = m.descriptors[0] else { Issue.record("no OOL region"); return }
        #expect(data == payload)
        #expect(m.body == Self.ndr + Self.le(UInt32(payload.count)))
        #expect(m.replyType == MachMsgType.portSendOnce)
        #expect(m.sender != nil)
        let frame = try #require(a.lock.withLock { a.frames.first })
        #expect(frame["type"] as? String == "relay-request" && frame["id"] as? Int == 1000)
        let s = a.relay.statistics
        #expect(s.requestsOut == 1 && s.repliesOut == 1 && s.bytesOut == payload.count + 12 && s.roundTripsMs.count == 1)
        #expect(b.relay.statistics.requestsIn == 1 && b.relay.statistics.oneWayMs.count == 1)
    }

    @Test func largeRegionsCross() throws {
        let (a, b, server) = try pair()
        defer { finish(a, b, server) }
        for size in [67_765, 1 << 20, 8 << 20] {
            var payload = [UInt8](repeating: 0, count: size)
            for i in stride(from: 0, to: size, by: 4093) { payload[i] = UInt8(truncatingIfNeeded: i / 4093 + size) }
            let r = try send(a, to: b.udid, payload)
            #expect(try replyCode(a, r).code == 0)
            let m = try #require(server.lock.withLock { server.received.last })
            guard case let .ool(data, _, _) = m.descriptors.first else { Issue.record("no OOL"); return }
            #expect(data.count == size && data == payload)
        }
        // Over the limit: answered at once with MACH_SEND_TOO_LARGE, nothing sent.
        let small = Device("CCCCCCCC-0000-0000-0000-000000000003",
                           options: .init(requestTimeout: 10, lookupWait: 1, maximumPayload: 1024))
        let r = try send(small, to: b.udid, [UInt8](repeating: 1, count: 2048))
        #expect(try replyCode(small, r).code == MachMsgReturn.sendTooLarge)
        small.relay.stop(link: small)
    }

    /// H-16 (health-simulation.md §5.1, §8.7): healthd's sync messages over
    /// `health.sync.classc` are 693 B … 88 679 B (median 1 427 B) in one
    /// session, larger for a big backlog. Each crosses in one frame, byte for
    /// byte, in order, without pieces, and quickly (the relay adds no delay).
    @Test func healthSyncSizedMessagesCrossInOneFrame() throws {
        let (a, b, server) = try pair()
        defer { finish(a, b, server) }
        let sizes = [693, 781, 1_427, 88_679, 92_160, 262_144]
        for (n, size) in sizes.enumerated() {
            var payload = [UInt8](repeating: 0, count: size)
            for i in stride(from: 0, to: size, by: 211) { payload[i] = UInt8(truncatingIfNeeded: i / 211 + n) }
            let started = Date()
            let r = try send(a, to: b.udid, payload, id: Int32(1000 + n))
            #expect(try replyCode(a, r).code == 0)
            #expect(Date().timeIntervalSince(started) < 2)
            let m = try #require(server.lock.withLock { server.received.last })
            #expect(m.id == Int32(1000 + n))
            guard case let .ool(data, _, _) = m.descriptors.first else { Issue.record("no OOL"); return }
            #expect(data == payload)
        }
        #expect(server.lock.withLock { server.received.map(\.id) } == (0..<sizes.count).map { Int32(1000 + $0) })
        let s = a.relay.statistics
        #expect(s.chunkedOut == 0 && s.largestOut == 262_144 + 12)
    }

    /// P-12 (device-pairing.md §11.3, §12): a 20 MiB `transferFile` is one
    /// request of the file's size; it crosses in pieces, byte for byte.
    @Test func aTwentyMebibyteRequestCrossesInPieces() throws {
        let (a, b, server) = try pair()
        defer { finish(a, b, server) }
        let size = 20 << 20
        var payload = [UInt8](repeating: 0, count: size)
        for i in stride(from: 0, to: size, by: 997) { payload[i] = UInt8(truncatingIfNeeded: i / 997) }
        let r = try send(a, to: b.udid, payload)
        #expect(try replyCode(a, r, timeout: 30_000_000_000).code == 0)
        let m = try #require(server.lock.withLock { server.received.last })
        #expect(m.id == 1000 && m.size == 56 && m.body == Self.ndr + Self.le(UInt32(size)))
        guard case let .ool(data, _, _) = m.descriptors.first else { Issue.record("no OOL"); return }
        #expect(data.count == size && data == payload)
        let frames = a.lock.withLock { a.frames }
        let chunks = frames.filter { $0["type"] as? String == "relay-chunk" }
        #expect(chunks.count == 5)  // 4 MiB pieces
        #expect(chunks.allSatisfy { (($0["data"] as? Data)?.count ?? 0) <= 4 << 20 })
        let request = try #require(frames.last { $0["type"] as? String == "relay-request" })
        #expect(request["ool"] == nil && (request["oolSizes"] as? [Int]) == [size])
        // Every frame fits the rendezvous socket's frame limit (17 MiB, PairLinkFrame).
        #expect(frames.allSatisfy {
            ((try? PropertyListSerialization.data(fromPropertyList: $0, format: .binary, options: 0))?.count ?? .max) <= 17 << 20
        })
        let s = a.relay.statistics
        #expect(s.chunkedOut == 1 && s.chunksOut == 5 && s.largestOut == size + 12)
    }

    /// Later requests wait behind a large one (order per direction), and the
    /// far half's queued bytes stay within its bound.
    @Test func piecesKeepTheOrderUnderTheMemoryBound() throws {
        let options = PairingTransportRelay.Options(requestTimeout: 20, lookupWait: 1, chunkSize: 1 << 20, queuedLimit: 3 << 20)
        let (a, b, server) = try pair(options)
        defer { finish(a, b, server) }
        let sizes = [9 << 20, 100, 2 << 20 + 5, 7, 5 << 20]
        var replies: [UInt32] = []
        for (i, n) in sizes.enumerated() {
            replies.append(try send(a, to: b.udid, [UInt8](repeating: UInt8(i + 1), count: n)))
        }
        for r in replies { #expect(try replyCode(a, r, timeout: 30_000_000_000).code == 0) }
        let got = server.lock.withLock { server.received }.map { m -> (Int, UInt8) in
            guard case let .ool(data, _, _) = m.descriptors.first else { return (-1, 0) }
            return (data.count, data.first ?? 0)
        }
        #expect(got.map(\.0) == sizes && got.map(\.1) == [1, 2, 3, 4, 5])
    }

    @Test func manyRequestsInFlightKeepTheirOrderAndRepliesFindTheirSenders() throws {
        // B holds every request; then answers them in reverse order, each with
        // RetCode = the index in its payload.
        let (a, b, server) = try pair { _ in nil }
        defer { finish(a, b, server) }
        var ports: [UInt32] = []
        for i in 0..<50 { ports.append(try send(a, to: b.udid, Self.le(UInt32(i)) + [UInt8](repeating: UInt8(i), count: 100 + i))) }
        #expect(waitUntil { server.count == 50 })
        let held = server.lock.withLock { server.held }
        let order = held.map { m -> UInt32 in
            guard case let .ool(d, _, _) = m.descriptors[0] else { return 9999 }
            return Self.word(d, 0)
        }
        #expect(order == (0..<50).map(UInt32.init))  // delivered in send order, all before any reply
        for m in held.reversed() {
            guard case let .ool(d, _, _) = m.descriptors[0] else { continue }
            server.reply(m, code: 1000 + Self.word(d, 0))
        }
        for (i, p) in ports.enumerated() { #expect(try replyCode(a, p).code == UInt32(1000 + i)) }
        #expect(a.relay.statistics.repliesOut == 50)
    }

    @Test func bothDirectionsAtOnce() throws {
        let opts = PairingTransportRelay.Options(requestTimeout: 10, lookupWait: 1)
        let (a, b, serverB) = try pair(opts)
        let serverA = try GuestServer(host: a.host)
        a.guestNames[opts.localName] = serverA.port
        defer { serverA.stop(); finish(a, b, serverB) }
        var toB: [UInt32] = [], toA: [UInt32] = []
        for i in 0..<20 {
            toB.append(try send(a, to: b.udid, [UInt8](repeating: UInt8(i), count: 500)))
            toA.append(try send(b, to: a.udid, [UInt8](repeating: UInt8(i), count: 700)))
        }
        for p in toB { #expect(try replyCode(a, p).code == 0) }
        for p in toA { #expect(try replyCode(b, p).code == 0) }
        #expect(serverA.count == 20 && serverB.count == 20)
    }

    @Test func aSimpleRoutineNeedsNoReply() throws {
        let (a, b, server) = try pair()
        defer { finish(a, b, server) }
        try send(a, to: b.udid, [1, 2, 3, 4], id: 1001, reply: false)
        #expect(waitUntil { server.count == 1 })
        let m = try #require(server.lock.withLock { server.received.first })
        #expect(m.id == 1001 && !MachPortName.isValid(m.replyPort))
    }

    @Test func aLostLinkAnswersWaitingRequestsWithInvalidDestination() throws {
        let (a, b, server) = try pair { _ in nil }
        defer { finish(a, b, server) }
        let waiting = try (0..<3).map { _ in try send(a, to: b.udid, [9, 9, 9]) }
        #expect(waitUntil { server.count == 3 })
        a.setLinked(false)
        b.setLinked(false)
        a.relay.linkChanged(peer: b.udid, up: false, link: a)
        b.relay.linkChanged(peer: a.udid, up: false, link: b)
        for p in waiting { #expect(try replyCode(a, p, timeout: 2_000_000_000).code == MachMsgReturn.sendInvalidDest) }
        // B's late replies go nowhere (their reply ports are gone).
        for m in server.lock.withLock({ server.held }) { server.reply(m, code: 0) }
        // A request after the loss: answered at once, never sent.
        let r = try send(a, to: b.udid, [1])
        #expect(try replyCode(a, r, timeout: 2_000_000_000).code == MachMsgReturn.sendInvalidDest)
        #expect(server.count == 3)
    }

    @Test func aMissingOrDeadLocalPortIsAnInvalidDestination() throws {
        let opts = PairingTransportRelay.Options(requestTimeout: 10, lookupWait: 0.5)
        let (a, b, server) = try pair(opts)
        defer { finish(a, b, server) }
        // Found, then the service goes away (its port dies): the cached right
        // is dead, one new look-up fails too.
        #expect(try replyCode(a, try send(a, to: b.udid, [1])).code == 0)
        server.stop()
        try b.host.destroyPort(server.port)
        b.lock.withLock { b.guestNames = [:] }
        let t0 = Date()
        #expect(try replyCode(a, try send(a, to: b.udid, [2])).code == MachMsgReturn.sendInvalidDest)
        #expect(Date().timeIntervalSince(t0) < 5)
        // Not registered at all: looked up again until lookupWait, then refused.
        #expect(try replyCode(a, try send(a, to: b.udid, [3])).code == MachMsgReturn.sendInvalidDest)
        #expect(b.lock.withLock { b.lookups } >= 3)
    }

    @Test func aLateLookUpSucceedsWithinTheWait() throws {
        let opts = PairingTransportRelay.Options(requestTimeout: 10, lookupWait: 5)
        let (a, b, server) = try pair(opts)
        defer { finish(a, b, server) }
        b.lock.withLock { b.guestNames = [:] }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { b.lock.withLock { b.guestNames[opts.localName] = server.port } }
        #expect(try replyCode(a, try send(a, to: b.udid, [1, 2])).code == 0)
    }

    @Test func noAnswerInTimeIsATimeout() throws {
        let (a, b, server) = try pair(.init(requestTimeout: 0.5, lookupWait: 0.2)) { _ in nil }
        defer { finish(a, b, server) }
        let r = try send(a, to: b.udid, [5, 5])
        let t0 = Date()
        #expect(try replyCode(a, r).code == MachMsgReturn.sendTimedOut)
        #expect(Date().timeIntervalSince(t0) < 3)
        #expect(a.relay.statistics.timedOutOut == 1)
        // The far half lets go of its reply port: B's late reply goes nowhere.
        Thread.sleep(forTimeInterval: 0.6)
        let m = try #require(server.lock.withLock { server.held.first })
        server.reply(m, code: 0)
        Thread.sleep(forTimeInterval: 0.3)
        #expect(a.relay.statistics.repliesOut == 0 && a.relay.statistics.failedOut == 1)
    }

    @Test func aDroppedReplyRightIsServerDied() throws {
        // B's server takes the request and drops the reply right.
        let (a, b, server) = try pair { _ in nil }
        defer { finish(a, b, server) }
        let r = try send(a, to: b.udid, [7])
        #expect(waitUntil { server.count == 1 })
        let m = try #require(server.lock.withLock { server.held.first })
        try b.host.deallocate(m.replyPort)
        #expect(try replyCode(a, r).code == MachKern.migServerDied)
    }

    @Test func aRequestWithRightsIsRefused() throws {
        let (a, b, server) = try pair()
        defer { finish(a, b, server) }
        let endpoint = try a.host.makePort(sendRight: true)
        let extra = try a.host.makePort(sendRight: true)
        let reply = try a.host.makePort()
        try a.host.send(MachHostOutgoingMessage(remotePort: endpoint, localPort: reply, localDisposition: MachMsgType.makeSendOnce,
                                                id: 1000, descriptors: [.port(name: extra, disposition: MachMsgType.copySend)],
                                                body: Self.ndr))
        let m = try a.host.receive(on: endpoint, timeout: 1_000_000_000)
        a.relay.endpoint(peer: b.udid, received: m, link: a)
        #expect(try replyCode(a, reply).code == MachMsgReturn.sendInvalidRight)
        #expect(server.count == 0)
    }

    @Test func framesOfAnOldLinkAreIgnored() throws {
        let (a, b, server) = try pair { _ in nil }
        defer { finish(a, b, server) }
        let r = try send(a, to: b.udid, [1])
        #expect(waitUntil { server.count == 1 })
        // The link drops and comes back before B answers: A's request was
        // answered at the drop; B's answer, of the old link, finds nothing.
        a.relay.linkChanged(peer: b.udid, up: false, link: a)
        a.relay.linkChanged(peer: b.udid, up: true, link: a)
        #expect(try replyCode(a, r).code == MachMsgReturn.sendInvalidDest)
        a.relay.link(peer: b.udid, received: ["type": "relay-reply", "seq": 1, "generation": 1, "code": 0, "id": 1100,
                                              "body": Data(Self.ndr + Self.le(0))], link: a)
        #expect(a.relay.statistics.repliesOut == 0)
        #expect(!a.relay.link(peer: b.udid, received: ["type": "registered"], link: a))
    }
}
