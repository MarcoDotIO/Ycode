// The host end of vhmdd, the visionOS guest's virtual head-mounted-display
// daemon (specs/simulator/visionos.md §5.5.3, §5.5.4; "Ycode implementation"
// there). ycode-simd opens an XPC connection to the guest name
// `com.apple.vhmdd` the way a host process does: the name's send right from
// launchd_sim's control channel (702 find endpoint), the connection
// hand-shake of iosurface-remote.md §2.2 (a receive right for the
// connection port, a send right to the client's own event port), and every
// payload in the sim-to-host encoding (`!CPX`, iosurface-remote.md §2.1).
// Commands are XPC dictionaries with the command name under `cmd`:
//
//   get_pose                  → {pose: data(64)}  column-major float4x4
//   set_pose {pose}           → {}                ARKit's DeviceAnchor follows it
//   request_environments      → {}, then the event environments_changed {environments_data: JSON}
//   set_active_environment {environment_id}
//                             → {}, then active_environment_changed (twice) and
//                               synthetic_environment_did_load {environment_id, load_error}
//
// Events arrive on the event port (one-way 0x10000000 messages).

import Foundation
import YcodeDarwinKernel
import YcodeDisplayStream
import YcodeXPC

public final class VisionHMDClient: @unchecked Sendable {
    public static let serviceName = "com.apple.vhmdd"
    static let handshakeID: Int32 = 0x7730_3074
    static let requestID: Int32 = 0x1000_0000
    static let replyID: Int32 = 0x2000_0000

    public enum ClientError: Error, CustomStringConvertible, Equatable {
        case notConnected
        case timedOut(String)
        case badReply(String)
        public var description: String {
            switch self {
            case .notConnected: "vhmdd: not connected"
            case .timedOut(let c): "vhmdd: no reply to \(c)"
            case .badReply(let c): "vhmdd: unexpected reply to \(c)"
            }
        }
    }

    /// One simulated room (§2.6).
    public struct Room: Equatable, Sendable {
        public var key: String
        public var displayName: String
    }

    let host: MachHostTask
    /// The guest name's send right (a host-task name), from 702.
    let find: () throws -> UInt32
    let log: (String) -> Void
    private let lock = NSCondition()
    private var connection: UInt32?
    private var eventPort: UInt32?
    private var eventThread: Thread?
    private var stopping = false
    private let requestLock = NSLock()
    /// The rooms of the last environments_changed (sorted by key).
    public private(set) var rooms: [Room] = []
    /// The active room as vhmdd last reported it.
    public private(set) var activeRoom: String?
    /// The last synthetic_environment_did_load: (room, load_error).
    private var lastLoad: (String, String)?
    /// Every event (diagnostics, tests).
    public var onEvent: ((XPCDict) -> Void)?
    /// set_pose is latest-wins on its own thread (one XPC round trip each).
    private var pendingPose: SpatialPose?
    private var poseThread: Thread?
    public private(set) var posesSent = 0

    public init(host: MachHostTask, find: @escaping () throws -> UInt32, log: @escaping (String) -> Void) {
        self.host = host
        self.find = find
        self.log = log
    }

    public var isConnected: Bool { lock.withLock { connection != nil } }

    // MARK: Connection

    /// Opens the connection (once; again after a failure).
    public func connect() throws {
        if isConnected { return }
        let service = try find()
        defer { try? host.deallocate(service) }
        // The connection port: its receive right goes to vhmdd, its send right stays.
        let c = try host.makePort(sendRight: true)
        let e = try host.makePort(qlimit: 64)
        do {
            try host.send(MachHostOutgoingMessage(remotePort: service, remoteDisposition: MachMsgType.copySend, id: Self.handshakeID,
                                                  descriptors: [.port(name: c, disposition: MachMsgType.moveReceive),
                                                                .port(name: e, disposition: MachMsgType.makeSend)]),
                          timeout: 1_000_000_000)
        } catch {
            try? host.deallocate(c)
            try? host.destroyPort(e)
            throw error
        }
        lock.withLock {
            connection = c
            eventPort = e
        }
        let t = Thread { [weak self] in self?.receiveEvents(on: e) }
        t.name = "ycode-vhmdd-events"
        t.start()
        eventThread = t
        log("vhmdd: connected (sim-to-host connection to \(Self.serviceName))")
    }

    public func stop() {
        lock.withLock {
            stopping = true
            lock.broadcast()
        }
    }

    private func disconnected(_ why: String) {
        let (c, e) = lock.withLock { () -> (UInt32?, UInt32?) in
            defer { connection = nil; eventPort = nil }
            return (connection, eventPort)
        }
        if let c { try? host.deallocate(c) }
        if let e { try? host.destroyPort(e) }
        log("vhmdd: connection closed (\(why)); the next command connects again")
    }

    // MARK: Requests

    /// One command and its reply dictionary.
    public func request(_ command: String, _ extra: [(String, XPCObject)] = [], timeout: UInt64 = 3_000_000_000) throws -> XPCDict {
        try connect()
        requestLock.lock()
        defer { requestLock.unlock() }
        guard let c = lock.withLock({ connection }) else { throw ClientError.notConnected }
        var d = XPCDict()
        d.append(key: "cmd", value: .string(command))
        for (k, v) in extra { d.append(key: k, value: v) }
        let encoded = try XPCWire.encode(.dictionary(d), magic: XPCWire.sim2hostMagic)
        let reply = try host.makePort()
        defer { try? host.destroyPort(reply) }
        do {
            try host.send(MachHostOutgoingMessage(remotePort: c, remoteDisposition: MachMsgType.copySend, localPort: reply,
                                                  localDisposition: MachMsgType.makeSendOnce, id: Self.requestID,
                                                  body: encoded.body), timeout: 1_000_000_000)
        } catch {
            disconnected("send failed: \(error)")
            throw error
        }
        let m: MachHostReceivedMessage
        do {
            m = try host.receive(on: reply, timeout: timeout)
        } catch let e as MachHostError where e == .timedOut {
            throw ClientError.timedOut(command)
        }
        defer { drop(m) }
        guard m.id == Self.replyID, let object = try? decode(m), case let .dictionary(r) = object else {
            // A send-once notification (vhmdd dropped the request) or an error.
            if m.isFromKernel { disconnected("vhmdd dropped the request (\(command))") }
            throw ClientError.badReply(command)
        }
        return r
    }

    func decode(_ m: MachHostReceivedMessage) throws -> XPCObject {
        let wire: [XPCWireDescriptor] = m.descriptors.map {
            switch $0 {
            case let .port(name, type): return .port(name: name, disposition: type)
            case let .ool(data, _, _): return .ool(bytes: data)
            case let .oolPorts(names, type): return .oolPorts(names: names, disposition: type)
            case let .guardedPort(name, _, type): return .guardedPort(name: name, disposition: type)
            }
        }
        return try XPCWire.decode(body: m.body, descriptors: wire)
    }

    private func drop(_ m: MachHostReceivedMessage) {
        var names: [UInt32] = []
        if MachPortName.isValid(m.replyPort) { names.append(m.replyPort) }
        for d in m.descriptors {
            switch d {
            case let .port(name, _), let .guardedPort(name, _, _): names.append(name)
            case let .oolPorts(list, _): names += list
            case .ool: break
            }
        }
        for n in names where MachPortName.isValid(n) { try? host.deallocate(n) }
    }

    // MARK: Commands

    /// vhmdd's pose (identity after boot; the matrix of the last set_pose).
    public func getPose() throws -> SpatialPose {
        let r = try request("get_pose")
        guard let bytes = r["pose"]?.dataValue, let pose = SpatialPose(matrixBytes: bytes) else { throw ClientError.badReply("get_pose") }
        return pose
    }

    /// Sends set_pose now and waits for its reply.
    public func setPoseNow(_ pose: SpatialPose) throws {
        _ = try request("set_pose", [("pose", .data(pose.matrixBytes))])
    }

    /// Queues set_pose (latest wins; sent from its own thread so a camera
    /// drag never waits for the guest).
    public func setPose(_ pose: SpatialPose) {
        let start = lock.withLock { () -> Bool in
            pendingPose = pose
            lock.broadcast()
            return poseThread == nil
        }
        guard start else { return }
        let t = Thread { [weak self] in self?.poseLoop() }
        t.name = "ycode-vhmdd-pose"
        lock.withLock { poseThread = t }
        t.start()
    }

    private func poseLoop() {
        while true {
            let next = lock.withLock { () -> SpatialPose? in
                while pendingPose == nil && !stopping { lock.wait(until: Date(timeIntervalSinceNow: 1)) }
                defer { pendingPose = nil }
                return pendingPose
            }
            guard let next else { return }
            do {
                try setPoseNow(next)
                let n = lock.withLock { () -> Int in posesSent += 1; return posesSent }
                if n <= 3 { log("vhmdd: set_pose \(n): \(next)") }
            } catch {
                log("vhmdd: set_pose failed: \(error)")
                Thread.sleep(forTimeInterval: 0.5)
            }
        }
    }

    /// Asks for the room list; waits up to `wait` seconds for environments_changed.
    @discardableResult
    public func requestEnvironments(wait: TimeInterval = 3) throws -> [Room] {
        let before = lock.withLock { roomsGeneration }
        _ = try request("request_environments")
        let deadline = Date(timeIntervalSinceNow: wait)
        return lock.withLock {
            while roomsGeneration == before && Date() < deadline { lock.wait(until: deadline) }
            return rooms
        }
    }

    private var roomsGeneration = 0

    /// Switches the room live; waits up to `wait` seconds for
    /// synthetic_environment_did_load. Returns its load_error ("" on success),
    /// or nil when it did not come in time.
    public func setActiveEnvironment(_ key: String, wait: TimeInterval = 15) throws -> String? {
        lock.withLock { lastLoad = nil }
        _ = try request("set_active_environment", [("environment_id", .string(key))])
        let deadline = Date(timeIntervalSinceNow: wait)
        return lock.withLock {
            while (lastLoad == nil || lastLoad?.0 != key) && Date() < deadline { lock.wait(until: deadline) }
            return lastLoad?.0 == key ? lastLoad?.1 : nil
        }
    }

    // MARK: Events

    private func receiveEvents(on port: UInt32) {
        while true {
            if lock.withLock({ stopping || eventPort != port }) { return }
            let m: MachHostReceivedMessage
            do {
                m = try host.receive(on: port, timeout: 250_000_000)
            } catch let e as MachHostError where e == .timedOut || e == .interrupted {
                continue
            } catch {
                return
            }
            defer { drop(m) }
            guard let object = try? decode(m), case let .dictionary(d) = object else {
                if m.isFromKernel { disconnected("vhmdd's end went away (message \(m.id))"); return }
                continue
            }
            handleEvent(d)
        }
    }

    /// One event dictionary from vhmdd (public for tests).
    public func handleEvent(_ d: XPCDict) {
        let cmd = d["cmd"]?.stringValue ?? "?"
        switch cmd {
        case "environments_changed":
            let list = Self.rooms(fromJSON: d["environments_data"]?.stringValue ?? "")
            lock.withLock {
                rooms = list
                roomsGeneration += 1
                lock.broadcast()
            }
            log("vhmdd: rooms: " + list.map(\.key).joined(separator: ", "))
        case "active_environment_changed":
            let key = d["environment_id"]?.stringValue
            lock.withLock { activeRoom = key }
            log("vhmdd: active room \(key ?? "?")")
        case "synthetic_environment_did_load":
            let key = d["environment_id"]?.stringValue ?? ""
            let error = d["load_error"]?.stringValue ?? ""
            lock.withLock {
                lastLoad = (key, error)
                activeRoom = key
                lock.broadcast()
            }
            log("vhmdd: room \(key) loaded" + (error.isEmpty ? "" : " with error: \(error)"))
        default:
            log("vhmdd: event \(cmd): \(d.keys.joined(separator: ", "))")
        }
        onEvent?(d)
    }

    /// The rooms of environments_data: a JSON object keyed by room key, each
    /// `{displayName, thumbnailURL}` (§5.5.4). Sorted by key.
    public static func rooms(fromJSON text: String) -> [Room] {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        return object.keys.sorted().map { key in
            Room(key: key, displayName: (object[key] as? [String: Any])?["displayName"] as? String ?? key)
        }
    }

    /// The six rooms of the runtime (§2.6, §5.5.4), for a device that is not running.
    public static let knownRooms = ["KitchenDay", "KitchenNight", "LivingRoomDay", "LivingRoomNight", "MuseumDay", "MuseumNight"]
}
