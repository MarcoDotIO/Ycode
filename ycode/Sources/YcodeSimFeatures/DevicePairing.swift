// Pairing an iPhone simulator with an Apple Watch simulator
// (specs/simulator/device-pairing.md §2, §7: P-1 … P-5; §8 for Ycode's
// decisions). The parts every host shares, in plain Foundation:
//
//   - the pair records of a device set (`DevicePairStore`, P-1) and the
//     rules of who may pair with whom (`PairingRules`, §2.3);
//   - the `list-pairs` listing (§2.2), text and JSON;
//   - the order of the host's requests while both devices of a pair run
//     (`PairingSequencer`, §3.1, §3.2, §4.1, P-4, P-5);
//   - the frames of the host channel to Ycode's guest pairing agent and of
//     the link between the two devices' `ycode-simd` processes.
//
// Record format (Ycode's own): `<device set>/ycode-device-pairs.plist`, an
// XML property list
//   { Version: 1, DevicePairs: { <pair UUID>: { active: bool, companion: <phone UDID>,
//     gizmo: <watch UDID>, companionDirectory: <name>, gizmoDirectory: <name> } } }
// with the reference's three keys per pair (§2.1) plus the device directories
// (relative to the set), which Ycode uses to find a device by its directory.
// Writes are atomic and serialized with a lock file next to the records.

import Foundation

// MARK: - Devices and rules

/// What a device is for pairing (UIKit's device family; `UIDeviceFamily` 1 / 4).
public enum PairingFamily: String, Sendable, Equatable {
    /// An iPhone: the companion of a pair.
    case phone
    /// An Apple Watch: the gizmo of a pair.
    case watch
    /// Anything else (iPad, Apple Vision Pro): does not pair.
    case other
}

/// A device of the device set as the pairing commands see it.
public struct PairingDevice: Sendable, Equatable {
    public var udid: String
    /// The device directory's name inside the set (or its full path when outside).
    public var directory: String
    public var family: PairingFamily
    /// The device type's display name ("iPhone 18 Pro").
    public var typeName: String
    /// The OS version the device last booted ("27.0"); nil before its first boot.
    public var osVersion: String?

    public init(udid: String, directory: String, family: PairingFamily, typeName: String, osVersion: String? = nil) {
        self.udid = udid.uppercased()
        self.directory = directory
        self.family = family
        self.typeName = typeName
        self.osVersion = osVersion
    }
}

/// Who may pair (§2.3, from the runtimes' pairing requirements; Ycode's own
/// data, the reference's values).
public enum PairingRules {
    /// The most pairs a device of `family` may be in: a watch one phone, a
    /// phone up to 100 watches.
    public static func maxPairs(_ family: PairingFamily) -> Int {
        switch family {
        case .watch: 1
        case .phone: 100
        case .other: 0
        }
    }

    /// The oldest partner OS a device of `family` pairs with: a watch's
    /// runtime wants iOS 12.0 or later, a phone's runtime watchOS 3.2 or later.
    public static func minimumPartnerOS(_ family: PairingFamily) -> String? {
        switch family {
        case .watch: "12.0"
        case .phone: "3.2"
        case .other: nil
        }
    }

    /// Compares dotted versions numerically ("27.0" ≥ "12.0").
    public static func version(_ a: String, isAtLeast b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return true
    }
}

/// A refused pairing command (§2.2). The texts are Ycode's own; `exitStatus`
/// is what `ycode-simd` exits with.
public enum PairingError: Error, Equatable, CustomStringConvertible {
    /// Phone + phone, watch + watch, or a device that never pairs (iPad, Vision).
    case doesNotPair(String)
    /// A device already in as many pairs as it may be (a watch with a second phone).
    case tooManyPairs(String)
    /// The partner's OS is older than the device's runtime accepts.
    case partnerTooOld(device: String, partnerVersion: String, minimum: String)
    case sameDevice
    case noSuchPair(String)
    case alreadyActive(String)
    case alreadyPaired(String)

    public var description: String {
        switch self {
        case .doesNotPair(let what): "Unable to pair devices: \(what) does not support pairing"
        case .tooManyPairs(let what): "Unable to pair devices: \(what) is already paired with the maximum number of devices"
        case let .partnerTooOld(device, partner, minimum):
            "Unable to pair devices: \(device) needs a partner on OS \(minimum) or later (it has \(partner))"
        case .sameDevice: "Unable to pair devices: a device cannot pair with itself"
        case .noSuchPair(let id): "Invalid device pair: \(id)"
        case .alreadyActive(let id): "The pair \(id) is already active"
        case .alreadyPaired(let id): "Unable to pair devices: they are already paired (pair \(id))"
        }
    }

    /// `simctl`'s status for an unknown pair (148) and the POSIX errno of
    /// "already active" (37, EALREADY); 1 for the other refusals.
    public var exitStatus: Int32 {
        switch self {
        case .noSuchPair: 148
        case .alreadyActive: 37
        default: 1
        }
    }
}

// MARK: - Records

/// One pair (§2.1): a phone (companion) and a watch (gizmo).
public struct DevicePair: Sendable, Equatable {
    /// The pair's UUID (upper case).
    public var id: String
    /// The phone's UDID.
    public var companion: String
    /// The watch's UDID.
    public var gizmo: String
    public var active: Bool
    /// The device directories (relative to the set), when known.
    public var companionDirectory: String?
    public var gizmoDirectory: String?

    public init(id: String, companion: String, gizmo: String, active: Bool,
                companionDirectory: String? = nil, gizmoDirectory: String? = nil) {
        self.id = id.uppercased()
        self.companion = companion.uppercased()
        self.gizmo = gizmo.uppercased()
        self.active = active
        self.companionDirectory = companionDirectory
        self.gizmoDirectory = gizmoDirectory
    }

    /// The other device of the pair, for `udid` (nil if `udid` is in neither role).
    public func peer(of udid: String) -> String? {
        let u = udid.uppercased()
        if u == companion { return gizmo }
        if u == gizmo { return companion }
        return nil
    }

    public func contains(_ udid: String) -> Bool { peer(of: udid) != nil }

    var plist: [String: Any] {
        var d: [String: Any] = ["active": active, "companion": companion, "gizmo": gizmo]
        if let companionDirectory { d["companionDirectory"] = companionDirectory }
        if let gizmoDirectory { d["gizmoDirectory"] = gizmoDirectory }
        return d
    }

    init?(id: String, plist: [String: Any]) {
        guard let c = plist["companion"] as? String, let g = plist["gizmo"] as? String else { return nil }
        self.init(id: id, companion: c, gizmo: g, active: (plist["active"] as? Bool) ?? false,
                  companionDirectory: plist["companionDirectory"] as? String, gizmoDirectory: plist["gizmoDirectory"] as? String)
    }
}

/// The pair records of one device set (P-1).
public struct DevicePairStore: Sendable, Equatable {
    public static let fileName = "ycode-device-pairs.plist"
    public static let lockFileName = ".ycode-device-pairs.lock"
    public static let formatVersion = 1

    /// In a stable order (by pair UUID).
    public private(set) var pairs: [DevicePair]

    public init(pairs: [DevicePair] = []) { self.pairs = pairs.sorted { $0.id < $1.id } }

    public static func path(inSet set: String) -> String { (set as NSString).appendingPathComponent(fileName) }

    // MARK: Reading and writing

    /// The records of the set (empty when there is no file). Throws on a file that is not a record file.
    public static func load(set: String) throws -> DevicePairStore {
        guard let data = FileManager.default.contents(atPath: path(inSet: set)) else { return DevicePairStore() }
        return try DevicePairStore(data: data)
    }

    public init(data: Data) throws {
        guard let root = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            throw CocoaError(.propertyListReadCorrupt)
        }
        let dict = root["DevicePairs"] as? [String: Any] ?? [:]
        self.init(pairs: dict.compactMap { id, value in (value as? [String: Any]).flatMap { DevicePair(id: id, plist: $0) } })
    }

    public func data() throws -> Data {
        var dict: [String: Any] = [:]
        for p in pairs { dict[p.id] = p.plist }
        return try PropertyListSerialization.data(fromPropertyList: ["Version": Self.formatVersion, "DevicePairs": dict],
                                                  format: .xml, options: 0)
    }

    public func save(set: String) throws {
        try data().write(to: URL(fileURLWithPath: Self.path(inSet: set)), options: .atomic)
    }

    /// Runs `body` on the set's records under the set's lock file and saves
    /// the result (when `body` returns without throwing).
    @discardableResult
    public static func update<R>(set: String, _ body: (inout DevicePairStore) throws -> R) throws -> R {
        let lockPath = (set as NSString).appendingPathComponent(lockFileName)
        let fd = open(lockPath, O_CREAT | O_RDWR | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        defer { close(fd) }
        flock(fd, LOCK_EX)
        defer { flock(fd, LOCK_UN) }
        var store = try load(set: set)
        let result = try body(&store)
        try store.save(set: set)
        return result
    }

    // MARK: Queries

    public func pair(_ id: String) -> DevicePair? { pairs.first { $0.id == id.uppercased() } }

    /// Every pair `udid` is in.
    public func pairs(of udid: String) -> [DevicePair] { pairs.filter { $0.contains(udid) } }

    /// The phone's active pair, if any.
    public func activePair(ofPhone udid: String) -> DevicePair? {
        pairs.first { $0.companion == udid.uppercased() && $0.active }
    }

    // MARK: Commands (§2.2)

    /// Pairs two devices (either order: the roles come from the families).
    /// The phone's first pair is active; a further pair is inactive unless
    /// the phone has no active pair. `newID` makes the pair UUID (tests).
    public mutating func pair(_ a: PairingDevice, _ b: PairingDevice,
                              newID: () -> String = { UUID().uuidString }) throws -> DevicePair {
        guard a.udid != b.udid else { throw PairingError.sameDevice }
        for d in [a, b] where d.family == .other { throw PairingError.doesNotPair(d.typeName) }
        guard a.family != b.family else { throw PairingError.doesNotPair("\(a.typeName) with \(b.typeName)") }
        let phone = a.family == .phone ? a : b, watch = a.family == .watch ? a : b
        if let existing = pairs.first(where: { $0.companion == phone.udid && $0.gizmo == watch.udid }) {
            throw PairingError.alreadyPaired(existing.id)
        }
        for d in [phone, watch] where pairs(of: d.udid).count >= PairingRules.maxPairs(d.family) {
            throw PairingError.tooManyPairs("\(d.typeName) (\(d.udid))")
        }
        // Each side's runtime names the oldest partner OS it accepts.
        for (d, partner) in [(phone, watch), (watch, phone)] {
            if let minimum = PairingRules.minimumPartnerOS(d.family), let v = partner.osVersion,
               !PairingRules.version(v, isAtLeast: minimum) {
                throw PairingError.partnerTooOld(device: d.typeName, partnerVersion: v, minimum: minimum)
            }
        }
        let new = DevicePair(id: newID(), companion: phone.udid, gizmo: watch.udid, active: activePair(ofPhone: phone.udid) == nil,
                             companionDirectory: phone.directory, gizmoDirectory: watch.directory)
        pairs.append(new)
        pairs.sort { $0.id < $1.id }
        return new
    }

    /// Removes a pair (§2.2: unpairing the active pair activates no other).
    public mutating func unpair(_ id: String) throws -> DevicePair {
        guard let i = pairs.firstIndex(where: { $0.id == id.uppercased() }) else { throw PairingError.noSuchPair(id) }
        return pairs.remove(at: i)
    }

    /// Makes a pair active and the phone's other pairs inactive.
    public mutating func activate(_ id: String) throws -> DevicePair {
        guard let i = pairs.firstIndex(where: { $0.id == id.uppercased() }) else { throw PairingError.noSuchPair(id) }
        guard !pairs[i].active else { throw PairingError.alreadyActive(pairs[i].id) }
        let phone = pairs[i].companion
        for j in pairs.indices where pairs[j].companion == phone { pairs[j].active = j == i }
        return pairs[i]
    }
}

// MARK: - Listing (§2.2 `list pairs`)

/// What `list-pairs` shows for one pair.
public struct PairListingEntry: Sendable, Equatable {
    public struct Side: Sendable, Equatable {
        public var name: String
        public var udid: String
        /// "Booted" or "Shutdown".
        public var state: String
        public init(name: String, udid: String, state: String) {
            self.name = name
            self.udid = udid
            self.state = state
        }
    }

    public var id: String
    public var watch: Side
    public var phone: Side
    public var active: Bool
    /// Both devices run and the pairing endpoint is registered in both guests.
    public var connected: Bool

    public init(id: String, watch: Side, phone: Side, active: Bool, connected: Bool) {
        self.id = id
        self.watch = watch
        self.phone = phone
        self.active = active
        self.connected = connected
    }

    /// "(active, connected)", "(inactive, disconnected)", …
    public var stateText: String { "(\(active ? "active" : "inactive"), \(connected ? "connected" : "disconnected"))" }
}

public enum PairListing {
    public static func text(_ entries: [PairListingEntry]) -> String {
        var lines = ["== Device Pairs =="]
        for e in entries {
            lines.append("\(e.id) \(e.stateText)")
            lines.append("    Watch: \(e.watch.name) (\(e.watch.udid)) (\(e.watch.state))")
            lines.append("    Phone: \(e.phone.name) (\(e.phone.udid)) (\(e.phone.state))")
        }
        return lines.joined(separator: "\n")
    }

    /// `{ "pairs": { <UUID>: { "watch": {name, udid, state}, "phone": {…}, "state": "(active, connected)" } } }`
    public static func json(_ entries: [PairListingEntry]) -> String {
        func side(_ s: PairListingEntry.Side) -> [String: Any] { ["name": s.name, "udid": s.udid, "state": s.state] }
        var pairs: [String: Any] = [:]
        for e in entries { pairs[e.id] = ["watch": side(e.watch), "phone": side(e.phone), "state": e.stateText] }
        let data = (try? JSONSerialization.data(withJSONObject: ["pairs": pairs], options: [.prettyPrinted, .sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - The pairing endpoint (§4.1)

public enum PairingEndpoint {
    /// The host-side name the host registers in a guest for its paired peer:
    /// `com.apple.IDSSimRPC.remote.<peer UDID>` (an interop name, §4.1).
    public static func remoteName(peer: String) -> String { "com.apple.IDSSimRPC.remote." + peer.uppercased() }
    /// The name of a guest's own transport port (its `ids_simd`; §4.1), which
    /// the relay (W5) looks up in the peer.
    public static let localName = "com.apple.IDSSimRPC.local"
    /// MIG ids of the transport (§4.3): the request and its reply.
    public static let requestID: Int32 = 1000
    public static let replyID: Int32 = 1100
}

// MARK: - Requests to the guest agent (§3.1, P-4)

/// One request of the host to the guest pairing agent, the equivalent of the
/// reference bridge's five pairing requests (§3.1).
public enum PairingAgentRequest: Sendable, Equatable {
    /// "Connect to remote <peer>": the transport's connect for the peer.
    case connect(peer: String)
    /// "Make <peer> the active pair". The agent reads the guest's own
    /// registry (§11.1): peer active → nothing; present → switch; absent →
    /// pair. `previouslyPaired` is the host's record, used only when the
    /// registry cannot be read.
    case setActive(peer: String, previouslyPaired: Bool)
    /// Set-active for a peer that does not run (an activation, P-11): the
    /// agent switches when the registry has the peer and does nothing
    /// otherwise (the pairing then comes with set-active when the peer
    /// runs; Ycode decision, so no request waits minutes for an absent peer).
    case switchTo(peer: String)
    /// At boot: remove the guest's pairs the host no longer has.
    case removeUnpaired(hostPaired: [String])
    /// "Unpair from remote <peer>".
    case unpair(peer: String)
    /// "Disconnect from remote <peer>".
    case disconnect(peer: String)

    public var op: String {
        switch self {
        case .connect: "connect"
        case .setActive, .switchTo: "setActive"
        case .removeUnpaired: "removeUnpaired"
        case .unpair: "unpair"
        case .disconnect: "disconnect"
        }
    }

    /// The request's frame body (the host adds `id`).
    public var message: [String: Any] {
        switch self {
        case .connect(let p), .unpair(let p), .disconnect(let p): ["op": op, "peer": p]
        case let .setActive(p, before): ["op": op, "peer": p, "previouslyPaired": before, "peerRunning": true]
        case .switchTo(let p): ["op": op, "peer": p, "peerRunning": false]
        case .removeUnpaired(let list): ["op": op, "hostPaired": list]
        }
    }

    /// One line for logs.
    public var summary: String {
        switch self {
        case .connect(let p): "connect \(p)"
        case let .setActive(p, before): "set-active \(p)\(before ? " (paired before)" : "")"
        case .switchTo(let p): "set-active \(p) (not running: switch only)"
        case .removeUnpaired(let list): "remove-unpaired (host pairs: \(list.isEmpty ? "none" : list.joined(separator: ", ")))"
        case .unpair(let p): "unpair \(p)"
        case .disconnect(let p): "disconnect \(p)"
        }
    }
}

/// The host channel to Ycode's guest pairing agent: the same frames as the
/// settings channel (`SettingsChannel`: a 4-byte big-endian length, an XML
/// property list with a dictionary root), at its own guest path.
///
/// Host → agent: { id, op, … } (`PairingAgentRequest.message`), or { id, op: "ping" }.
/// Agent → host: { event: "hello", pid, version } first, then replies
/// { id, ok: bool, error?: string, detail?: string }.
public enum PairingAgentChannel {
    public static let guestPaths = ["/private/var/run/dev.ycode.pairing", "/var/run/dev.ycode.pairing"]
    public static let protocolVersion = 1
}

// MARK: - The order of the host's requests (P-4, P-5)

/// What the host does for one device while it runs, decided from events in
/// the order the reference shows (§3.1, §3.2, §4.1):
///
///   - at boot, once the agent is up: remove-unpaired with the host's pairs;
///   - when the peer of a pair also runs (the link between the two hosts is
///     up) and this guest's control session is bound: register
///     `remote.<peer>` (701) and tell the peer;
///   - when both guests have the endpoint and the agent is up: connect, then
///     set-active if the pair is the active one (the watch's only pair; the
///     phone's active pair);
///   - when the peer stops (the link goes down): unregister the name (709)
///     and destroy the port, then disconnect to the agent (§11.1, P-11);
///   - a pair made active while its peer does not run: a switch-only
///     set-active at once (`switchTo`, P-11, §12.2), or without
///     `switchAbsentPeers` nothing until the peer runs;
///   - unpair while both run: on the phone, unpair then disconnect.
///
/// Pure state: the caller performs the actions and reports their outcome.
public struct PairingSequencer: Sendable {
    public enum Action: Sendable, Equatable {
        case register(peer: String)
        case unregister(peer: String)
        /// Tell the peer's host that this guest has its endpoint.
        case announceRegistered(peer: String)
        case agent(PairingAgentRequest)
    }

    /// Per peer.
    public struct PeerState: Sendable, Equatable {
        public var linked = false
        public var registering = false
        public var localRegistered = false
        public var peerRegistered = false
        public var connectSent = false
        public var activeSent = false
        public var active = false
        public var previouslyPaired = false
        /// Activated while not connected: a switch-only set-active is due.
        public var switchDue = false
        /// Both endpoints exist (`list-pairs` "connected").
        public var connected: Bool { linked && localRegistered && peerRegistered }
    }

    public private(set) var peers: [String: PeerState] = [:]
    /// Whether a pair made active while its watch does not run gets the
    /// switch-only set-active at once (true, the default, as the reference
    /// sends set-active at once) or only the normal set-active when the
    /// watch runs (false; device-pairing.md §12.2).
    public var switchAbsentPeers = true
    public private(set) var agentReady = false
    public private(set) var controlReady = false
    private var removeUnpairedSent = false
    /// The peers of every pair of the device (the host's pair list).
    public private(set) var hostPaired: [String] = []

    public init() {}

    public func state(of peer: String) -> PeerState { peers[peer.uppercased()] ?? PeerState() }

    /// The records changed (or were first read): the device's peers and which is active.
    public mutating func setPairs(_ list: [(peer: String, active: Bool, previouslyPaired: Bool)]) -> [Action] {
        hostPaired = list.map { $0.peer.uppercased() }.sorted()
        for (peer, active, before) in list {
            let p = peer.uppercased()
            var s = peers[p] ?? PeerState()
            if s.active != active {
                s.activeSent = false
                // Made active now (not the first reading of the records).
                s.switchDue = active && peers[p] != nil && !s.connected
            }
            s.active = active
            s.previouslyPaired = s.previouslyPaired || before
            peers[p] = s
        }
        return advance()
    }

    public mutating func agentConnected() -> [Action] {
        agentReady = true
        removeUnpairedSent = false
        // A new agent (a restart, a restore) has done nothing yet.
        for k in peers.keys {
            peers[k]!.connectSent = false
            peers[k]!.activeSent = false
        }
        return advance()
    }

    public mutating func agentDisconnected() { agentReady = false }

    /// The control session is bound (701 and 709 can be sent).
    public mutating func controlBound() -> [Action] {
        controlReady = true
        return advance()
    }

    public mutating func linkUp(peer: String) -> [Action] {
        let p = peer.uppercased()
        var s = peers[p] ?? PeerState()
        s.linked = true
        s.peerRegistered = false
        peers[p] = s
        return advance()
    }

    /// The peer's host says that the peer's guest has its endpoint for this device.
    public mutating func peerRegistered(peer: String) -> [Action] {
        let p = peer.uppercased()
        guard peers[p]?.linked == true else { return [] }
        peers[p]!.peerRegistered = true
        return advance()
    }

    /// The outcome of a `.register` action.
    public mutating func registered(peer: String, ok: Bool) -> [Action] {
        let p = peer.uppercased()
        guard var s = peers[p] else { return [] }
        s.registering = false
        s.localRegistered = ok && s.linked
        peers[p] = s
        if ok && !s.linked { return [.unregister(peer: p)] }  // the peer left while 701 was on its way
        return ok ? [.announceRegistered(peer: p)] + advance() : []
    }

    /// The outcome of a `.agent(.setActive)` action.
    public mutating func activated(peer: String, ok: Bool) {
        let p = peer.uppercased()
        if ok { peers[p]?.previouslyPaired = true }
    }

    /// The peer stopped (or the link broke): the endpoint goes, no agent request.
    public mutating func linkDown(peer: String) -> [Action] {
        let p = peer.uppercased()
        guard var s = peers[p], s.linked else { return [] }
        let had = s.localRegistered || s.registering
        // The survivor's agent is told the peer went (§11.1), when it had connected.
        let disconnect = agentReady && s.connectSent
        s.linked = false
        s.localRegistered = false
        s.peerRegistered = false
        s.connectSent = false
        s.activeSent = false
        peers[p] = s
        return (had ? [.unregister(peer: p)] : []) + (disconnect ? [.agent(.disconnect(peer: p))] : [])
    }

    /// The pair with `peer` was removed while this device runs (the phone's
    /// side of an unpair, §3.2): unpair then disconnect, then the endpoint goes.
    public mutating func unpaired(peer: String) -> [Action] {
        let p = peer.uppercased()
        let s = peers.removeValue(forKey: p) ?? PeerState()
        hostPaired.removeAll { $0 == p }
        var out: [Action] = []
        if agentReady && s.connectSent { out += [.agent(.unpair(peer: p)), .agent(.disconnect(peer: p))] }
        if s.localRegistered || s.registering { out.append(.unregister(peer: p)) }
        return out
    }

    private mutating func advance() -> [Action] {
        var out: [Action] = []
        if agentReady && !removeUnpairedSent {
            removeUnpairedSent = true
            out.append(.agent(.removeUnpaired(hostPaired: hostPaired)))
        }
        for p in peers.keys.sorted() {
            var s = peers[p]!
            if s.linked && controlReady && !s.localRegistered && !s.registering {
                s.registering = true
                out.append(.register(peer: p))
            }
            if s.connected { s.switchDue = false }
            if s.switchDue && s.active && agentReady && switchAbsentPeers {
                s.switchDue = false
                out.append(.agent(.switchTo(peer: p)))
            }
            if s.connected && agentReady {
                if !s.connectSent {
                    s.connectSent = true
                    out.append(.agent(.connect(peer: p)))
                }
                if s.active && !s.activeSent {
                    s.activeSent = true
                    out.append(.agent(.setActive(peer: p, previouslyPaired: s.previouslyPaired)))
                }
            }
            peers[p] = s
        }
        return out
    }
}

// MARK: - The link between two devices' hosts

/// The frames between two `ycode-simd` processes (the watch's and the
/// phone's) and between the pairing commands and a running `ycode-simd`: a
/// 4-byte big-endian length, then a binary property list with a dictionary
/// root and a `type` key. Types:
///   hello { udid, role: "gizmo"|"companion", pid, version }   (watch → phone, first frame of a link)
///   welcome { udid, pid }                                     (phone → watch; or `refused { reason }`)
///   registered { udid }                                       (this guest has remote.<peer>)
///   command { verb, args: [String] }                          (pairing commands → a running device; reply `answer`)
///   answer { ok: bool, text: String, state?: { … } }
/// W5 adds its relay frames (`relay …`) on the same link.
public enum PairLinkFrame {
    public static let protocolVersion = 1
    /// A larger frame is refused (both ends). A relay message whose
    /// out-of-line bytes exceed one 4 MiB piece crosses in several frames
    /// (P-12, §12), so no request size depends on this limit.
    public static let maximumFrame = 17 << 20

    public static func encode(_ message: [String: Any]) -> [UInt8]? {
        guard let data = try? PropertyListSerialization.data(fromPropertyList: message, format: .binary, options: 0),
              data.count <= maximumFrame else { return nil }
        let n = UInt32(data.count)
        return [UInt8(n >> 24), UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)] + [UInt8](data)
    }

    /// Splits complete frames off the front of `buffer` (consumed).
    public static func decode(_ buffer: inout [UInt8]) throws -> [[String: Any]] {
        var out: [[String: Any]] = []
        while let o = try decodeFirst(&buffer) { out.append(o) }
        return out
    }

    /// The first complete frame of `buffer` (consumed), or nil when the
    /// buffer does not hold a whole frame yet.
    public static func decodeFirst(_ buffer: inout [UInt8]) throws -> [String: Any]? {
        guard buffer.count >= 4 else { return nil }
        let n = Int(buffer[0]) << 24 | Int(buffer[1]) << 16 | Int(buffer[2]) << 8 | Int(buffer[3])
        guard n <= maximumFrame else { throw SettingsChannel.ChannelError.frameTooLarge(n) }
        guard buffer.count >= 4 + n else { return nil }
        let body = Data(buffer[4..<(4 + n)])
        buffer.removeFirst(4 + n)
        guard let o = try? PropertyListSerialization.propertyList(from: body, options: [], format: nil) as? [String: Any],
              o["type"] is String else {
            throw SettingsChannel.ChannelError.notADictionary
        }
        return o
    }

    /// The rendezvous socket of the running device with `udid`: one per
    /// device in the host's memory directory (short enough for a Unix
    /// socket path), so the two devices of a pair, and the pairing
    /// commands, find each other on one host without a broker.
    public static func socketPath(base: String, uid: UInt32, udid: String) -> String {
        let id = udid.uppercased().replacingOccurrences(of: "-", with: "").prefix(16)
        return (base.hasSuffix("/") ? String(base.dropLast()) : base) + "/ycodepair-\(uid)-\(id).sock"
    }
}
