import Crypto
import Foundation
import Testing
import YcodeDisplayStream
@testable import YcodeSimLink

/// The simulator link (specs/simulator/sim-link.md).
struct SimLinkTests {
    static func tempStore(_ name: String) -> LinkStore {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("ycode-simlink-\(name)-\(UUID().uuidString)")
        return LinkStore(directory: d)
    }

    // MARK: Noise

    func handshake(psk: [UInt8]? = nil, responderPSK: [UInt8]? = nil) throws -> (NoiseXX, NoiseXX, [UInt8], [UInt8]) {
        var i = NoiseXX(initiator: true, staticKey: Curve25519.KeyAgreement.PrivateKey(), prologue: [1, 2], psk: psk)
        var r = NoiseXX(initiator: false, staticKey: Curve25519.KeyAgreement.PrivateKey(), prologue: [1, 2], psk: responderPSK ?? psk)
        var h: [UInt8] = []
        let m1 = try i.writeMessage { _ in [] }
        _ = try r.readMessage(m1, hashBeforePayload: &h)
        let m2 = try r.writeMessage { _ in Array("two".utf8) }
        let p2 = try i.readMessage(m2, hashBeforePayload: &h)
        let m3 = try i.writeMessage { _ in Array("three".utf8) }
        let p3 = try r.readMessage(m3, hashBeforePayload: &h)
        return (i, r, p2, p3)
    }

    @Test func xxHandshakeAgreesAndEncrypts() throws {
        let (i, r, p2, p3) = try handshake()
        #expect(String(decoding: p2, as: UTF8.self) == "two")
        #expect(String(decoding: p3, as: UTF8.self) == "three")
        #expect(i.handshakeHash == r.handshakeHash)
        #expect(i.remoteStatic != nil && r.remoteStatic != nil)
        var (is_, ir) = try i.transportCiphers()
        var (rs, rr) = try r.transportCiphers()
        let c = try is_.encrypt(ad: [], Array("hello".utf8))
        #expect(try rr.decrypt(ad: [], c) == Array("hello".utf8))
        let d = try rs.encrypt(ad: [], [9, 9])
        #expect(try ir.decrypt(ad: [], d) == [9, 9])
        // Rekeyed on both sides, still in step.
        try is_.rekey(); try rr.rekey()
        let e = try is_.encrypt(ad: [], [7])
        #expect(try rr.decrypt(ad: [], e) == [7])
        // A replayed record fails (the receiver's nonce moved on), and so does a tampered one.
        #expect(throws: NoiseError.decryptFailed) { try rr.decrypt(ad: [], e) }
        var t = try is_.encrypt(ad: [], [1, 2, 3])
        t[0] ^= 1
        #expect(throws: NoiseError.decryptFailed) { try rr.decrypt(ad: [], t) }
    }

    @Test func pskMustMatch() throws {
        _ = try handshake(psk: [UInt8](repeating: 1, count: 32))
        #expect(throws: NoiseError.self) { _ = try handshake(psk: [UInt8](repeating: 1, count: 32), responderPSK: [UInt8](repeating: 2, count: 32)) }
    }

    @Test func noiseHKDFMatchesRFC5869Shape() {
        // Noise's HKDF with one output pair is RFC 5869 with an empty info and L = 64 (§4.3).
        let ck = [UInt8](repeating: 0x0b, count: 32), ikm = Array("ikm".utf8)
        let o = NoiseSymmetricState.hkdf(ck, ikm, 2)
        let rfc = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: ikm), salt: ck, info: [UInt8](), outputByteCount: 64)
        let bytes = rfc.withUnsafeBytes { Array($0) }
        #expect(o[0] + o[1] == bytes)
    }

    // MARK: Pairing and trust

    @Test func pairingCodesAndWindow() throws {
        let code = Pairing.newCode()
        #expect(code.count == 14 && code.split(separator: "-").count == 3)
        #expect(Pairing.psk(code: code) == Pairing.psk(code: code.lowercased().replacingOccurrences(of: "-", with: " ")))
        #expect(Pairing.normalize("abcO-I1L") == "ABC0111")
        let store = Self.tempStore("pair")
        try Pairing.open(code: code, store: store)
        #expect(Pairing.isOpen(store: store))
        #expect(Pairing.take(store: store) == Pairing.psk(code: code))
        #expect(Pairing.take(store: store) == nil)  // one attempt
        try Pairing.open(code: code, store: store, now: Date(timeIntervalSinceNow: -400))
        #expect(Pairing.take(store: store) == nil)  // expired
    }

    @Test func storeKeepsIdentityAndPeers() throws {
        let store = Self.tempStore("store")
        let a = try store.identity(), b = try store.identity()
        #expect(a.publicKey == b.publicKey)
        let attrs = try FileManager.default.attributesOfItem(atPath: store.directory.appendingPathComponent("identity.key").path)
        #expect((attrs[.posixPermissions] as? Int) == 0o600)
        try store.addPeer(TrustedPeer(name: "thor", publicKey: [UInt8](repeating: 3, count: 32), role: "host", address: "h:1"))
        try store.addPeer(TrustedPeer(name: "thor", publicKey: [UInt8](repeating: 4, count: 32), role: "host", address: "h:1"))
        #expect(store.peers().count == 1)  // a host name names one key
        #expect(store.trusted([UInt8](repeating: 4, count: 32), role: "host") != nil)
        #expect(store.trusted([UInt8](repeating: 4, count: 32), role: "client") == nil)
        #expect(LinkIdentity.fingerprint(a.publicKey).count == 24)
    }

    // MARK: Channels over loopback

    final class Pair: @unchecked Sendable {
        var result: Result<SecureChannel.Accepted, Error>?
    }

    /// A responder on a loopback listener, one connection.
    func respond(_ l: LinkListener, _ host: LinkIdentity, trusted: [UInt8]?, psk: [UInt8]? = nil) -> (Pair, DispatchSemaphore) {
        let out = Pair(), done = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            guard let (c, _) = l.accept() else { done.signal(); return }
            out.result = Result { try SecureChannel.accept(c, identity: host, pairingPSK: { psk }, authorize: { key, _, pairing in pairing || key == trusted }) }
            if case .success(let a) = out.result { try? a.channel.sendJSON(LinkWelcome(ok: true, host: "test")) }
            done.signal()
        }
        return (out, done)
    }

    @Test func pinnedChannelCarriesBytesBothWays() throws {
        let l = try LinkListener(host: "127.0.0.1", port: 0)
        defer { l.close() }
        let host = LinkIdentity(), client = LinkIdentity()
        let (r, done) = respond(l, host, trusted: client.publicKey)
        let (ch, welcome) = try SecureChannel.connect(host: "127.0.0.1", port: l.port, identity: client, check: .pinned(host.publicKey),
                                                     hello: LinkHello(purpose: "display", device: "p18", client: "test", media: true))
        done.wait()
        let accepted = try r.result!.get()
        #expect(welcome.ok && welcome.host == "test")
        #expect(accepted.hello.device == "p18" && accepted.channel.peerKey == client.publicKey)
        #expect(ch.peerKey == host.publicKey)
        #expect(ch.mediaKeys.initiatorToResponder == accepted.channel.mediaKeys.initiatorToResponder)
        // A large write arrives in records of at most 65 519 bytes, intact.
        let big = (0..<200_000).map { UInt8(truncatingIfNeeded: $0 &* 7) }
        try ch.send(big)
        var got: [UInt8] = []
        while got.count < big.count { got += try #require(accepted.channel.receive()) }
        #expect(got == big)
        try accepted.channel.send([1, 2, 3])
        #expect(ch.receive() == [1, 2, 3])
        ch.close()
        accepted.channel.close()
    }

    @Test func wrongHostKeyIsRefusedBeforeTheClientIdentifiesItself() throws {
        let l = try LinkListener(host: "127.0.0.1", port: 0)
        defer { l.close() }
        let host = LinkIdentity(), client = LinkIdentity()
        let (r, done) = respond(l, host, trusted: client.publicKey)
        #expect(throws: LinkError.self) {
            _ = try SecureChannel.connect(host: "127.0.0.1", port: l.port, identity: client, check: .pinned(LinkIdentity().publicKey),
                                          hello: LinkHello(purpose: "control", client: "test"), timeout: 2)
        }
        done.wait()
        if case .success = r.result! { Issue.record("the responder must not complete") }
    }

    @Test func untrustedClientIsRejected() throws {
        let l = try LinkListener(host: "127.0.0.1", port: 0)
        defer { l.close() }
        let host = LinkIdentity()
        let (r, done) = respond(l, host, trusted: LinkIdentity().publicKey)
        #expect(throws: LinkError.self) {
            _ = try SecureChannel.connect(host: "127.0.0.1", port: l.port, identity: LinkIdentity(), check: .pinned(host.publicKey),
                                          hello: LinkHello(purpose: "control", client: "x"), timeout: 2)
        }
        done.wait()
        guard case .failure = r.result! else { Issue.record("an untrusted client got in"); return }
    }

    @Test func pairingNeedsTheCode() throws {
        let host = LinkIdentity()
        for (clientCode, ok) in [("ABCD-EFGH-JKMN", true), ("ABCD-EFGH-JKMP", false)] {
            let l = try LinkListener(host: "127.0.0.1", port: 0)
            defer { l.close() }
            let (r, done) = respond(l, host, trusted: nil, psk: Pairing.psk(code: "ABCD-EFGH-JKMN"))
            let attempt = Result { try SecureChannel.connect(host: "127.0.0.1", port: l.port, identity: LinkIdentity(), check: .pairing(code: clientCode),
                                                             hello: LinkHello(purpose: "pair", client: "x"), timeout: 2) }
            done.wait()
            switch (attempt, ok) {
            case (.success(let (ch, _)), true): #expect(ch.peerKey == host.publicKey)
            case (.failure, false): if case .success = r.result! { Issue.record("wrong code accepted by the host") }
            default: Issue.record("pairing with \(clientCode): \(attempt)")
            }
        }
    }

    @Test func garbageBeforeTheHandshakeIsDropped() throws {
        let l = try LinkListener(host: "127.0.0.1", port: 0)
        defer { l.close() }
        let (r, done) = respond(l, LinkIdentity(), trusted: nil)
        let c = try DisplayConnection.connect(to: .tcp(host: "127.0.0.1", port: UInt16(l.port)))
        try c.send(Array("GET / HTTP/1.1\r\n\r\n".utf8))
        done.wait()
        #expect(throws: LinkError.protocolViolation("preamble")) { try r.result!.get() }
        c.close()
    }

    // MARK: Media

    @Test func mediaPacketsAuthenticateAndRejectReplays() throws {
        let k = SymmetricKey(size: .bits256)
        var s = MediaCrypto(key: k, session: 77, direction: 1)
        var r = MediaCrypto(key: k, session: 77, direction: 1)
        let p = try s.seal([1, 2, 3])
        #expect(r.open(p, expectDirection: 1) == [1, 2, 3])
        #expect(r.open(p, expectDirection: 1) == nil)  // replay
        var t = try s.seal([4])
        t[t.count - 1] ^= 1
        #expect(r.open(t, expectDirection: 1) == nil)  // tampered
        let q = try s.seal([5])
        #expect(r.open(q, expectDirection: 2) == nil)  // wrong direction
        var other = MediaCrypto(key: k, session: 78, direction: 1)
        #expect(r.open(try other.seal([6]), expectDirection: 1) == nil)  // another session
        #expect(r.open(q, expectDirection: 1) == [5])
    }

    @Test func replayWindowSlides() {
        var w = ReplayWindow()
        #expect(w.accept(5) && !w.accept(5))
        #expect(w.accept(3) && w.accept(10_000) && !w.accept(3))
        #expect(w.accept(9_999) && !w.accept(10_000 - ReplayWindow.size))
    }

    @Test func reassemblyDeliversInOrderAndReportsLoss() {
        var r = MediaReassembler()
        let a = Array(repeating: UInt8(1), count: 3000), b = Array(repeating: UInt8(2), count: 10), c = Array(repeating: UInt8(3), count: 2500)
        let fa = MediaPayload.fragments(of: a, id: 0), fb = MediaPayload.fragments(of: b, id: 1), fc = MediaPayload.fragments(of: c, id: 2)
        #expect(fa.count == 3 && fb.count == 1 && fc.count == 3)
        #expect(r.add(fa[2], now: 0).isEmpty)
        #expect(r.add(fa[0], now: 0).isEmpty)
        #expect(r.add(fa[1], now: 0) == [.message(a)])
        // Message 1 is lost; 2 completes and overtakes it.
        for f in fc.dropLast() { #expect(r.add(f, now: 1).isEmpty) }
        #expect(r.add(fc.last!, now: 1) == [.lost(1), .message(c)])
        #expect(r.add(fb[0], now: 2).isEmpty)  // late: stale
        // A partial message times out.
        let fd = MediaPayload.fragments(of: c, id: 3)
        _ = r.add(fd[0], now: 10)
        #expect(r.expire(now: 10 + MediaReassembler.timeout + 1) == [.lost(3)])
        #expect(r.lost == 2)
    }

    // MARK: Archive

    @Test func archiveRoundTripsATree() throws {
        let fm = FileManager.default
        let src = fm.temporaryDirectory.appendingPathComponent("arch-src-\(UUID().uuidString)")
        try fm.createDirectory(at: src.appendingPathComponent("A.app/Sub"), withIntermediateDirectories: true)
        try Data("bin".utf8).write(to: src.appendingPathComponent("A.app/A"))
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: src.appendingPathComponent("A.app/A").path)
        try Data(repeating: 7, count: 3 << 20).write(to: src.appendingPathComponent("A.app/Sub/big"))
        try fm.createSymbolicLink(atPath: src.appendingPathComponent("A.app/link").path, withDestinationPath: "Sub/big")
        let bytes = try DirectoryArchive.bytes(of: src.appendingPathComponent("A.app"))
        let dst = fm.temporaryDirectory.appendingPathComponent("arch-dst-\(UUID().uuidString)")
        var at = 0
        let n = try DirectoryArchive.extract(into: dst) { k in
            guard at + k <= bytes.count else { return nil }
            defer { at += k }
            return Array(bytes[at..<(at + k)])
        }
        #expect(n == bytes.count)
        #expect(fm.contents(atPath: dst.appendingPathComponent("A").path) == Data("bin".utf8))
        #expect((try fm.attributesOfItem(atPath: dst.appendingPathComponent("A").path)[.posixPermissions] as? Int) == 0o755)
        #expect(fm.contents(atPath: dst.appendingPathComponent("Sub/big").path)?.count == 3 << 20)
        #expect(try fm.destinationOfSymbolicLink(atPath: dst.appendingPathComponent("link").path) == "Sub/big")
    }

    @Test func archiveRefusesEscapes() throws {
        func archive(_ kind: UInt8, _ path: String, _ body: [UInt8]) -> [UInt8] {
            let p = Array(path.utf8)
            return [kind] + DirectoryArchive.le(UInt64(p.count), 2) + p + DirectoryArchive.le(0o644, 4) + DirectoryArchive.le(UInt64(body.count), 8) + body + [0]
        }
        for bad in [archive(2, "../x", [1]), archive(2, "/etc/x", [1]), archive(2, "a//b", []), archive(3, "l", Array("../../x".utf8)),
                    archive(3, "l", Array("/etc".utf8))] {
            let dst = FileManager.default.temporaryDirectory.appendingPathComponent("arch-bad-\(UUID().uuidString)")
            var at = 0
            #expect(throws: DirectoryArchive.Failure.self) {
                try DirectoryArchive.extract(into: dst) { k in
                    guard at + k <= bad.count else { return nil }
                    defer { at += k }
                    return Array(bad[at..<(at + k)])
                }
            }
        }
    }

    // MARK: Host configuration

    @Test func hostConfigurationAndLaunchArguments() throws {
        let text = """
            # comment
            YCODE_SIM_HOME=/data/area
            YCODE_SIM_TREE='/data/tree'
            YCODE_SIM_RUNTIME=/rt/27.1
            YCODE_SIM_RUNTIME_IPHONE_18_PRO=/rt/27.0
            YCODE_SIM_PRISTINE_IPHONE_18_PRO=/data/p18
            YCODE_SIMHOST_LISTEN=0.0.0.0:48000
            """
        let c = try SimHostConfig.load(text: text, environment: [:])
        #expect(c.controlPort == 48000 && c.mediaPort == LinkDefaults.mediaPort)
        #expect(c.runtime(for: "iphone-18-pro") == "/rt/27.0" && c.runtime(for: "ipad-a16") == "/rt/27.1")
        #expect(c.pristines["iphone-18-pro"] == "/data/p18")
        let (env, args) = c.launch(device: "p18", type: "iphone-18-pro", app: "/data/area/apps/A.app", bundleID: "com.x.a", cold: true)
        #expect(env["YCODE_WARM_BOOT"] == "1" && env["YCODE_WARM_FORCE_COLD"] == "1" && env["YCODE_SIM_DATA"] == "/data/area")
        #expect(args == ["--device", "/data/area/devices/p18", "--runtime-root", "/rt/27.0", "--display-server", "unix:/data/area/run/p18.sock",
                         "--device-type", "iphone-18-pro", "--install-app", "/data/area/apps/A.app", "--launch", "com.x.a", "--environment-overrides"])
        // Under the debugger (debug.md, "The Linux IDE: apps on the simulator"): the stub on a socket in the run folder.
        let debugged = c.launch(device: "p18", type: "iphone-18-pro", app: "/data/area/apps/A.app", bundleID: "com.x.a", cold: false, debug: true).args
        #expect(Array(debugged.suffix(2)) == ["--debug-server", "unix:/data/area/run/p18.debug.sock"])
        #expect(c.debugSocketPath("p18") == "/data/area/run/p18.debug.sock")
        #expect(!c.launch(device: "p18", type: "", app: nil, bundleID: nil, cold: false, debug: true).args.contains("--debug-server"))
        #expect(throws: LinkError.self) { try SimHostConfig.load(text: "", environment: [:]) }
        #expect(isSafeName("p18") && !isSafeName("../x") && !isSafeName(".hidden") && !isSafeName("a/b"))
        #expect(SimRemoteCLI.viewerArguments(host: "thor", device: "p18", extra: ["--status"]) == ["--link", "p18", "--host", "thor", "--status"])
    }

    @Test func runRequestsCarryTheDebuggerFlagAndTheStubSocket() throws {
        let r = LinkRequest(op: "run", device: "tc", app: "T.app", bundleID: "x.t", debug: true)
        let back = try JSONDecoder().decode(LinkRequest.self, from: JSONEncoder().encode(r))
        #expect(back.debug == true && back == r)
        // Requests and answers of hosts and clients without the fields still decode.
        let old = try JSONDecoder().decode(LinkRequest.self, from: Data(#"{"op":"run","device":"tc","app":"T.app"}"#.utf8))
        #expect(old.debug == nil)
        var a = LinkResponse(ok: true, message: "tc starting")
        a.debugSocket = "/h/run/tc.debug.sock"
        #expect(try JSONDecoder().decode(LinkResponse.self, from: JSONEncoder().encode(a)).debugSocket == "/h/run/tc.debug.sock")
        #expect(try JSONDecoder().decode(LinkResponse.self, from: Data(#"{"ok":true}"#.utf8)).debugSocket == nil)
    }

    @Test func splitterCutsWholeMessages() {
        var s = MessageSplitter()
        let a = DisplayMessage.notice("hi").encoded(), b = DisplayMessage.keyframeRequest.encoded()
        let all = a + b
        s.append(Array(all.prefix(3)))
        #expect(s.next() == nil)
        s.append(Array(all.dropFirst(3)))
        #expect(s.next() == a)
        #expect(s.next() == b)
        #expect(s.next() == nil)
    }
}
