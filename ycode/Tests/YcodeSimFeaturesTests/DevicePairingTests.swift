import Foundation
import Testing
@testable import YcodeSimFeatures

/// PAIR-HOST (specs/simulator/device-pairing.md §2, §3, §7 P-1 … P-5, §8):
/// the pair records and their rules, the listing, the order of the host's
/// requests while both devices run, and the link frames.
struct DevicePairStoreTests {
    let phone = PairingDevice(udid: "11111111-1111-1111-1111-111111111111", directory: "p18", family: .phone,
                              typeName: "iPhone 18 Pro", osVersion: "27.0")
    let phone2 = PairingDevice(udid: "22222222-2222-2222-2222-222222222222", directory: "p18b", family: .phone,
                               typeName: "iPhone 18 Pro", osVersion: "27.1")
    let watch = PairingDevice(udid: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa", directory: "w12", family: .watch,
                              typeName: "Apple Watch Series 12 (46mm)", osVersion: "27.0")
    let watch2 = PairingDevice(udid: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB", directory: "w12b", family: .watch,
                               typeName: "Apple Watch Series 12 (46mm)", osVersion: "27.0")
    let pad = PairingDevice(udid: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC", directory: "pad", family: .other, typeName: "iPad Pro")

    func ids() -> () -> String {
        var n = 0
        return { n += 1; return String(format: "00000000-0000-0000-0000-%012d", n) }
    }

    @Test func eitherOrderGivesTheRolesFromTheFamilies() throws {
        var a = DevicePairStore(), b = DevicePairStore()
        let p1 = try a.pair(watch, phone, newID: ids())
        let p2 = try b.pair(phone, watch, newID: ids())
        #expect(p1.companion == phone.udid && p1.gizmo == watch.udid.uppercased())
        #expect(p1.companion == p2.companion && p1.gizmo == p2.gizmo)
        #expect(p1.active)
        #expect(p1.companionDirectory == "p18" && p1.gizmoDirectory == "w12")
    }

    @Test func aPhonesFirstPairIsActiveAndTheNextInactive() throws {
        var s = DevicePairStore()
        let make = ids()
        let first = try s.pair(watch, phone, newID: make)
        let second = try s.pair(watch2, phone, newID: make)
        #expect(first.active && !second.active)
        #expect(s.activePair(ofPhone: phone.udid)?.id == first.id)
        // Unpairing the active pair activates no other (§2.2) …
        _ = try s.unpair(first.id)
        #expect(s.activePair(ofPhone: phone.udid) == nil)
        #expect(s.pair(second.id)?.active == false)
        // … and a new pair of a phone with no active pair is active.
        let third = try s.pair(watch, phone, newID: make)
        #expect(third.active)
    }

    @Test func aWatchHasOnePhone() throws {
        var s = DevicePairStore()
        _ = try s.pair(watch, phone, newID: ids())
        #expect(throws: PairingError.tooManyPairs("\(watch.typeName) (\(watch.udid))")) { try s.pair(watch, phone2) }
    }

    @Test func refusals() throws {
        var s = DevicePairStore()
        #expect(throws: PairingError.doesNotPair("iPhone 18 Pro with iPhone 18 Pro")) { try s.pair(phone, phone2) }
        #expect(throws: PairingError.doesNotPair("iPad Pro")) { try s.pair(pad, watch) }
        #expect(throws: PairingError.sameDevice) { try s.pair(watch, watch) }
        var old = watch
        old.osVersion = "3.1"
        #expect(throws: PairingError.partnerTooOld(device: "iPhone 18 Pro", partnerVersion: "3.1", minimum: "3.2")) { try s.pair(old, phone) }
        var oldPhone = phone
        oldPhone.osVersion = "11.4"
        #expect(throws: PairingError.partnerTooOld(device: watch.typeName, partnerVersion: "11.4", minimum: "12.0")) { try s.pair(watch, oldPhone) }
        let p = try s.pair(watch, phone, newID: ids())
        #expect(throws: PairingError.alreadyPaired(p.id)) { try s.pair(phone, watch) }
        #expect(s.pairs.count == 1)
    }

    @Test func aPhonePairsWithUpToAHundredWatches() throws {
        var s = DevicePairStore()
        let make = ids()
        for i in 0..<100 {
            let w = PairingDevice(udid: String(format: "AAAAAAAA-0000-0000-0000-%012d", i), directory: "w\(i)", family: .watch, typeName: "W")
            _ = try s.pair(w, phone, newID: make)
        }
        #expect(s.pairs.filter(\.active).count == 1)
        #expect(throws: PairingError.self) { try s.pair(watch, phone) }
    }

    @Test func activationAndItsErrors() throws {
        var s = DevicePairStore()
        let make = ids()
        let a = try s.pair(watch, phone, newID: make), b = try s.pair(watch2, phone, newID: make)
        #expect(throws: PairingError.alreadyActive(a.id)) { try s.activate(a.id) }
        _ = try s.activate(b.id.lowercased())
        #expect(s.pair(a.id)?.active == false && s.pair(b.id)?.active == true)
        #expect(throws: PairingError.noSuchPair("nope")) { try s.activate("nope") }
        #expect(throws: PairingError.noSuchPair("nope")) { try s.unpair("nope") }
        #expect(PairingError.noSuchPair("x").exitStatus == 148)
        #expect(PairingError.alreadyActive("x").exitStatus == 37)
        #expect(PairingError.sameDevice.exitStatus == 1)
    }

    @Test func recordsRoundTripThroughTheFile() throws {
        let dir = NSTemporaryDirectory() + "pairs-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        #expect(try DevicePairStore.load(set: dir).pairs.isEmpty)
        let made = try DevicePairStore.update(set: dir) { try $0.pair(watch, phone, newID: ids()) }
        let back = try DevicePairStore.load(set: dir)
        #expect(back.pairs == [made])
        let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: URL(fileURLWithPath: DevicePairStore.path(inSet: dir))),
                                                               format: nil) as? [String: Any]
        let entry = (plist?["DevicePairs"] as? [String: Any])?[made.id] as? [String: Any]
        #expect(plist?["Version"] as? Int == 1)
        #expect(entry?["active"] as? Bool == true)
        #expect(entry?["companion"] as? String == phone.udid)
        #expect(entry?["gizmo"] as? String == watch.udid.uppercased())
        // A refused command leaves the file as it was.
        #expect(throws: PairingError.self) { try DevicePairStore.update(set: dir) { try $0.pair(watch, phone2) } }
        #expect(try DevicePairStore.load(set: dir).pairs == [made])
    }

    @Test func versionsCompareNumerically() {
        #expect(PairingRules.version("27.0", isAtLeast: "12.0"))
        #expect(PairingRules.version("12", isAtLeast: "12.0"))
        #expect(!PairingRules.version("3.1.9", isAtLeast: "3.2"))
        #expect(PairingRules.maxPairs(.watch) == 1 && PairingRules.maxPairs(.phone) == 100 && PairingRules.maxPairs(.other) == 0)
    }
}

struct PairListingTests {
    @Test func textAndJSON() throws {
        let e = PairListingEntry(id: "P1", watch: .init(name: "Apple Watch Series 12 (46mm) [w]", udid: "W", state: "Booted"),
                                 phone: .init(name: "iPhone 18 Pro [p]", udid: "P", state: "Booted"), active: true, connected: true)
        #expect(PairListing.text([e]) == """
            == Device Pairs ==
            P1 (active, connected)
                Watch: Apple Watch Series 12 (46mm) [w] (W) (Booted)
                Phone: iPhone 18 Pro [p] (P) (Booted)
            """)
        var off = e
        off.active = false
        off.connected = false
        #expect(off.stateText == "(inactive, disconnected)")
        let json = try JSONSerialization.jsonObject(with: Data(PairListing.json([e]).utf8)) as? [String: Any]
        let pair = (json?["pairs"] as? [String: Any])?["P1"] as? [String: Any]
        #expect(pair?["state"] as? String == "(active, connected)")
        #expect((pair?["watch"] as? [String: Any])?["udid"] as? String == "W")
        #expect((pair?["phone"] as? [String: Any])?["state"] as? String == "Booted")
    }
}

struct PairingSequencerTests {
    let peer = "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"
    typealias A = PairingSequencer.Action

    @Test func theReferenceOrderWhenBothDevicesRun() {
        var s = PairingSequencer()
        #expect(s.setPairs([(peer, true, false)]).isEmpty)
        // At boot, once the agent is up: remove-unpaired with the host's pairs.
        #expect(s.agentConnected() == [.agent(.removeUnpaired(hostPaired: [peer]))])
        // Nothing is registered before the control session is bound and the peer runs.
        #expect(s.linkUp(peer: peer).isEmpty)
        #expect(s.controlBound() == [.register(peer: peer)])
        // 701 done: tell the peer; the agent waits for the peer's endpoint.
        #expect(s.registered(peer: peer, ok: true) == [.announceRegistered(peer: peer)])
        #expect(!s.state(of: peer).connected)
        // Both endpoints: connect, then set-active (§3.1, §3.2).
        #expect(s.peerRegistered(peer: peer) == [.agent(.connect(peer: peer)), .agent(.setActive(peer: peer, previouslyPaired: false))])
        #expect(s.state(of: peer).connected)
        // Nothing twice.
        #expect(s.controlBound().isEmpty)
        #expect(s.peerRegistered(peer: peer).isEmpty)
    }

    @Test func theAgentMayComeLast() {
        var s = PairingSequencer()
        _ = s.setPairs([(peer, true, true)])
        _ = s.controlBound()
        #expect(s.linkUp(peer: peer) == [.register(peer: peer)])
        _ = s.registered(peer: peer, ok: true)
        #expect(s.peerRegistered(peer: peer).isEmpty)  // no agent yet
        #expect(s.agentConnected() == [.agent(.removeUnpaired(hostPaired: [peer])), .agent(.connect(peer: peer)),
                                       .agent(.setActive(peer: peer, previouslyPaired: true))])
        // A restarted agent gets the requests again.
        s.agentDisconnected()
        #expect(s.agentConnected() == [.agent(.removeUnpaired(hostPaired: [peer])), .agent(.connect(peer: peer)),
                                       .agent(.setActive(peer: peer, previouslyPaired: true))])
    }

    @Test func anInactivePairIsConnectedButNotActivated() {
        var s = PairingSequencer()
        _ = s.setPairs([(peer, false, false)])
        _ = s.agentConnected()
        _ = s.controlBound()
        _ = s.linkUp(peer: peer)
        _ = s.registered(peer: peer, ok: true)
        #expect(s.peerRegistered(peer: peer) == [.agent(.connect(peer: peer))])
        // pair-activate while both run.
        #expect(s.setPairs([(peer, true, false)]) == [.agent(.setActive(peer: peer, previouslyPaired: false))])
    }

    @Test func aPeerThatStopsLosesItsEndpointAndTheAgentIsToldToDisconnect() {
        var s = PairingSequencer()
        _ = s.setPairs([(peer, true, false)])
        _ = s.agentConnected()
        _ = s.controlBound()
        _ = s.linkUp(peer: peer)
        _ = s.registered(peer: peer, ok: true)
        _ = s.peerRegistered(peer: peer)
        s.activated(peer: peer, ok: true)
        // §11.1, P-11: the survivor's agent gets disconnect.
        #expect(s.linkDown(peer: peer) == [.unregister(peer: peer), .agent(.disconnect(peer: peer))])
        #expect(!s.state(of: peer).connected)
        #expect(s.linkDown(peer: peer).isEmpty)
        // The peer boots again: register, then connect and set-active (paired before: a switch).
        #expect(s.linkUp(peer: peer) == [.register(peer: peer)])
        _ = s.registered(peer: peer, ok: true)
        #expect(s.peerRegistered(peer: peer) == [.agent(.connect(peer: peer)), .agent(.setActive(peer: peer, previouslyPaired: true))])
    }

    @Test func aRegistrationThatLandsAfterThePeerLeftIsUndone() {
        var s = PairingSequencer()
        _ = s.setPairs([(peer, true, false)])
        _ = s.controlBound()
        #expect(s.linkUp(peer: peer) == [.register(peer: peer)])
        #expect(s.linkDown(peer: peer) == [.unregister(peer: peer)])  // 701 was on its way
        #expect(s.registered(peer: peer, ok: true) == [.unregister(peer: peer)])
        #expect(s.registered(peer: peer, ok: false).isEmpty)
    }

    /// P-11: `pair-activate` of a pair whose watch does not run sends a
    /// switch-only set-active at once; the full set-active follows when the
    /// watch runs. A pair's first reading at boot sends nothing.
    @Test func activatingAPairWhoseWatchIsDownSwitchesAtOnce() {
        let other = "22222222-0000-4000-8000-000000000002"
        // YCODE_PAIRING_SWITCH_ABSENT=defer (§12.2): nothing until the watch runs.
        var d = PairingSequencer()
        d.switchAbsentPeers = false
        _ = d.setPairs([(peer, true, true), (other, false, true)])
        _ = d.agentConnected()
        _ = d.controlBound()
        #expect(d.setPairs([(peer, false, true), (other, true, true)]).isEmpty)
        #expect(d.linkUp(peer: other) == [.register(peer: other)])
        _ = d.registered(peer: other, ok: true)
        #expect(d.peerRegistered(peer: other) == [.agent(.connect(peer: other)), .agent(.setActive(peer: other, previouslyPaired: true))])
        // The default: the switch-only set-active at once.
        var s = PairingSequencer()
        #expect(s.switchAbsentPeers)
        #expect(s.setPairs([(peer, true, true), (other, false, true)]).isEmpty)
        _ = s.agentConnected()
        _ = s.controlBound()
        // pair-activate other (not running): switch only, at once.
        #expect(s.setPairs([(peer, false, true), (other, true, true)]) == [.agent(.switchTo(peer: other))])
        #expect(s.setPairs([(peer, false, true), (other, true, true)]).isEmpty)  // not twice
        // The watch boots: the normal order.
        #expect(s.linkUp(peer: other) == [.register(peer: other)])
        _ = s.registered(peer: other, ok: true)
        #expect(s.peerRegistered(peer: other) == [.agent(.connect(peer: other)), .agent(.setActive(peer: other, previouslyPaired: true))])
        // Activated while the agent is not up: sent when it comes.
        var t = PairingSequencer()
        _ = t.setPairs([(peer, true, true), (other, false, false)])
        #expect(t.setPairs([(peer, false, true), (other, true, false)]).isEmpty)
        #expect(t.agentConnected() == [.agent(.removeUnpaired(hostPaired: [other, peer].sorted())), .agent(.switchTo(peer: other))])
        // A new pair that is active at once (the phone's first): no switch; it pairs when the watch runs.
        var u = PairingSequencer()
        _ = u.agentConnected()
        #expect(u.setPairs([(peer, true, false)]).isEmpty)
    }

    @Test func unpairWhileBothRunUnpairsThenDisconnects() {
        var s = PairingSequencer()
        _ = s.setPairs([(peer, true, false)])
        _ = s.agentConnected()
        _ = s.controlBound()
        _ = s.linkUp(peer: peer)
        _ = s.registered(peer: peer, ok: true)
        _ = s.peerRegistered(peer: peer)
        #expect(s.unpaired(peer: peer) == [.agent(.unpair(peer: peer)), .agent(.disconnect(peer: peer)), .unregister(peer: peer)])
        #expect(s.hostPaired.isEmpty && s.peers.isEmpty)
        // Unpaired while the peer was not running: nothing to do in the guest.
        var t = PairingSequencer()
        _ = t.setPairs([(peer, true, false)])
        _ = t.agentConnected()
        #expect(t.unpaired(peer: peer).isEmpty)
    }

    @Test func requestFrames() {
        #expect(PairingAgentRequest.connect(peer: "P").message as NSDictionary == ["op": "connect", "peer": "P"])
        #expect(PairingAgentRequest.setActive(peer: "P", previouslyPaired: true).message as NSDictionary
                == ["op": "setActive", "peer": "P", "previouslyPaired": true, "peerRunning": true])
        #expect(PairingAgentRequest.switchTo(peer: "P").message as NSDictionary == ["op": "setActive", "peer": "P", "peerRunning": false])
        #expect(PairingAgentRequest.removeUnpaired(hostPaired: ["A"]).message as NSDictionary == ["op": "removeUnpaired", "hostPaired": ["A"]])
        #expect(PairingEndpoint.remoteName(peer: "ab-cd") == "com.apple.IDSSimRPC.remote.AB-CD")
    }
}

struct PairLinkFrameTests {
    @Test func framesRoundTripOneAtATime() throws {
        let a = PairLinkFrame.encode(["type": "hello", "udid": "U", "pid": 7])!
        let b = PairLinkFrame.encode(["type": "registered", "udid": "U"])!
        var buffer = a + b.prefix(3)
        let first = try PairLinkFrame.decodeFirst(&buffer)
        #expect(first?["type"] as? String == "hello" && first?["pid"] as? Int == 7)
        #expect(try PairLinkFrame.decodeFirst(&buffer) == nil)
        buffer += b.dropFirst(3)
        #expect(try PairLinkFrame.decode(&buffer).map { $0["type"] as? String } == ["registered"])
        #expect(buffer.isEmpty)
        // A frame without a type, or too large, is refused.
        let body = try PropertyListSerialization.data(fromPropertyList: ["x": 1], format: .binary, options: 0)
        var bad = [0, 0, 0, UInt8(body.count)] + [UInt8](body)
        #expect(throws: SettingsChannel.ChannelError.notADictionary) { try PairLinkFrame.decodeFirst(&bad) }
        var huge: [UInt8] = [0x7F, 0, 0, 0]
        #expect(throws: SettingsChannel.ChannelError.self) { try PairLinkFrame.decodeFirst(&huge) }
    }

    @Test func aMebibytePayloadFits() throws {
        let payload = Data(repeating: 0x5A, count: 1 << 20)
        var bytes = try #require(PairLinkFrame.encode(["type": "relay-request", "ool": payload]))
        let back = try PairLinkFrame.decodeFirst(&bytes)
        #expect((back?["ool"] as? Data)?.count == 1 << 20)
    }

    @Test func aSixteenMebibyteRelayRequestFitsAndMoreDoesNot() throws {
        // The relay's largest request (§10.2): 16 MiB of out-of-line bytes with its keys.
        let request: [String: Any] = ["type": "relay-request", "seq": 1, "generation": 1, "id": 1000, "reply": true,
                                      "body": Data(count: 12), "ool": [Data(repeating: 0xA5, count: 16 << 20)],
                                      "sent": NSNumber(value: UInt64.max)]
        var bytes = try #require(PairLinkFrame.encode(request))
        let back = try #require(try PairLinkFrame.decodeFirst(&bytes))
        #expect((back["ool"] as? [Data])?.first?.count == 16 << 20 && bytes.isEmpty)
        #expect(PairLinkFrame.encode(["type": "relay-request", "ool": [Data(count: 17 << 20)]]) == nil)
    }

    @Test func socketPathsAreShortAndPerDevice() {
        let p = PairLinkFrame.socketPath(base: "/dev/shm/", uid: 1000, udid: "8f3a2b1c-0000-4000-8000-123456789abc")
        #expect(p == "/dev/shm/ycodepair-1000-8F3A2B1C00004000.sock")
        #expect(p.utf8.count < 104)
    }
}
