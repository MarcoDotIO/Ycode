// The host's SystemConfiguration dynamic store, reduced to what
// configd_sim's SimulatorSupport plug-in needs to start
// (`specs/simulator/scdynamicstore-host.md`). Sessions open, notification
// requests are accepted; the store holds the guest's network state
// (`SCDynamicStoreNetworkState`, §7) and never changes, so no notification
// is ever sent. Wire protocol: the MIG subsystem `config` (20000) of Apple's
// open-source configd (`config.defs`).

import Foundation
import YcodeDarwinKernel

public final class SCDynamicStoreHostService: @unchecked Sendable {
    /// The names this one port is registered under (launchd-sim.md §6.3).
    public static let serviceNames = [
        "com.apple.SystemConfiguration.configd",
        "com.apple.SystemConfiguration.configd_host",
    ]
    /// `YCODE_DEBUG_NO_SCDYNAMICSTORE=1`: no service (diagnostics).
    public static let disabled = getenv("YCODE_DEBUG_NO_SCDYNAMICSTORE").map { String(cString: $0) == "1" } ?? false

    /// MIG message ids (`config.defs`).
    enum ID {
        static let configopen: Int32 = 20000, configlist: Int32 = 20008, configadd: Int32 = 20009,
                   configget: Int32 = 20010, configset: Int32 = 20011, configremove: Int32 = 20012,
                   configaddS: Int32 = 20014, confignotify: Int32 = 20015, configgetM: Int32 = 20016,
                   configsetM: Int32 = 20017, notifyadd: Int32 = 20018, notifyremove: Int32 = 20019,
                   notifychanges: Int32 = 20020, notifyviaport: Int32 = 20021, notifycancel: Int32 = 20024,
                   notifyset: Int32 = 20025, notifyviafd: Int32 = 20026, snapshot: Int32 = 20029
        /// `MACH_NOTIFY_NO_SENDERS`.
        static let noSenders: Int32 = 70
    }

    /// `kSCStatus*`.
    enum Status {
        static let ok: Int32 = 0, noKey: Int32 = 1004, noStoreSession: Int32 = 2001
    }

    /// `MIG_BAD_ID`.
    static let migBadID: Int32 = -303
    /// The NDR record (little-endian integers, IEEE floats, ASCII).
    static let ndr: [UInt8] = [0, 0, 0, 1, 0, 0, 0, 0]
    /// `MACH_MSG_TYPE_MAKE_SEND`, `MACH_MSG_TYPE_PORT_RECEIVE`.
    static let makeSend: UInt32 = 20, portReceive: UInt32 = 1

    public let servicePort: UInt32
    private let host: MachHostTask
    private let portSet: UInt32
    private let log: (String) -> Void
    private let lock = NSLock()
    private var stopping = false
    /// Open sessions: session port → notify rights received with
    /// notifyviaport (dropped when the session ends).
    private var sessions: [UInt32: [UInt32]] = [:]
    private var logged = 0
    /// Statistics.
    public private(set) var requestCount = 0

    public init(host: MachHostTask, log: @escaping (String) -> Void) throws {
        self.host = host
        self.log = log
        servicePort = try host.makePort(sendRight: true, qlimit: 64)
        portSet = try host.makePortSet()
        try host.addMember(servicePort, to: portSet)
    }

    public func start() {
        let t = Thread { [self] in run() }
        t.name = "ycode-scdynamicstore"
        t.start()
    }

    public func stop() { lock.withLock { stopping = true } }

    private func run() {
        while !lock.withLock({ stopping }) {
            let m: MachHostReceivedMessage
            do {
                m = try host.receive(on: portSet, timeout: 200_000_000, tracked: true)
            } catch let e as MachHostError where e == .timedOut || e == .interrupted || e == .portChanged {
                // portChanged: a session port of the set was destroyed meanwhile.
                continue
            } catch {
                if !lock.withLock({ stopping }) { log("scdynamicstore: receive failed: \(error); stopping") }
                return
            }
            handle(m)
            host.finishedMessage()
        }
    }

    // MARK: Requests

    func handle(_ m: MachHostReceivedMessage) {
        lock.withLock {
            requestCount += 1
            if logged < 16 {
                logged += 1
                log("scdynamicstore: request id \(m.id) on \(m.localPort == servicePort ? "service" : "session \(m.localPort)"), "
                    + "\(m.body.count) body bytes, \(m.descriptors.count) descriptors")
            }
        }
        if m.id == ID.noSenders, m.isFromKernel {
            endSession(m.localPort)
            return
        }
        guard MachPortName.isValid(m.replyPort) else {
            host.discard(m)
            return
        }
        let isSession = lock.withLock { sessions[m.localPort] != nil }
        if m.id == ID.configopen {
            guard m.localPort == servicePort else { return statusReply(m, Status.noStoreSession) }
            openSession(m)
            return
        }
        guard isSession else {
            dropRights(m)
            return statusReply(m, Status.noStoreSession)
        }
        switch m.id {
        case ID.configadd, ID.configaddS, ID.configset:
            dropRights(m)
            reply(m, body: Self.ndr + le(0) + le(0) + le(Status.ok))  // RetCode, newInstance, status
        case ID.configremove:
            statusReply(m, Status.noKey)
        case ID.confignotify, ID.configsetM, ID.notifyadd, ID.notifyremove, ID.notifycancel, ID.notifyset,
             ID.snapshot:
            statusReply(m, Status.ok)
        case ID.notifyviaport:
            // Keep the notify right for the session's life; nothing is ever sent.
            let kept = m.descriptors.compactMap { d -> UInt32? in
                if case let .port(name, _) = d { return name }
                return nil
            }
            lock.withLock { sessions[m.localPort, default: []] += kept }
            statusReply(m, Status.ok)
        case ID.notifyviafd:
            dropRights(m)
            statusReply(m, Status.ok)
        case ID.configget:
            // OOL data, NDR, dataCnt, newInstance, status (§7: the network keys).
            let key = oolData(m, 0).flatMap { SCDynamicStoreNetworkState.unserialize($0) as? String }
            if let key, let value = Self.store()[key], let data = SCDynamicStoreNetworkState.serialize(value) {
                reply(m, descriptors: [.ool(data: data)], body: Self.ndr + le(Int32(data.count)) + le(0) + le(Status.ok))
            } else {
                reply(m, descriptors: [.ool(data: [])], body: Self.ndr + le(0) + le(0) + le(Status.noKey))
            }
        case ID.configgetM:
            // A dictionary of key → serialized value (`_SCSerializeMultiple`).
            let keys = oolData(m, 0).flatMap { SCDynamicStoreNetworkState.unserialize($0) as? [String] } ?? []
            let patterns = oolData(m, 1).flatMap { SCDynamicStoreNetworkState.unserialize($0) as? [String] } ?? []
            let store = Self.store()
            var out: [String: Data] = [:]
            for k in SCDynamicStoreNetworkState.select(store, keys: keys, patterns: patterns) {
                if let d = SCDynamicStoreNetworkState.serialize(store[k]!) { out[k] = Data(d) }
            }
            if !out.isEmpty, let data = SCDynamicStoreNetworkState.serialize(out) {
                lock.withLock { if logged < 32 { logged += 1; log("scdynamicstore: copy multiple: \(out.keys.sorted().joined(separator: ", "))") } }
                reply(m, descriptors: [.ool(data: data)], body: Self.ndr + le(Int32(data.count)) + le(Status.ok))
            } else {
                reply(m, descriptors: [.ool(data: [])], body: Self.ndr + le(0) + le(Status.noKey))
            }
        case ID.configlist:
            // The keys matching a pattern (isRegex) or equal to the key.
            let key = oolData(m, 0).flatMap { SCDynamicStoreNetworkState.unserialize($0) as? String }
            let isRegex = m.body.count >= 16 && m.body[12..<16].contains { $0 != 0 }
            let store = Self.store()
            let keys = key.map { isRegex ? SCDynamicStoreNetworkState.select(store, keys: [], patterns: [$0])
                : SCDynamicStoreNetworkState.select(store, keys: [$0], patterns: []) } ?? []
            let list = SCDynamicStoreNetworkState.serialize(keys) ?? Self.emptyArrayPlist
            reply(m, descriptors: [.ool(data: list)], body: Self.ndr + le(Int32(list.count)) + le(Status.ok))
        case ID.notifychanges:
            let empty = Self.emptyArrayPlist
            reply(m, descriptors: [.ool(data: empty)], body: Self.ndr + le(Int32(empty.count)) + le(Status.ok))
        default:
            dropRights(m)
            reply(m, body: Self.ndr + le(Self.migBadID))
        }
    }

    private func openSession(_ m: MachHostReceivedMessage) {
        do {
            let session = try host.makePort()
            try host.addMember(session, to: portSet)
            lock.withLock { sessions[session] = [] }
            reply(m, descriptors: [.port(name: session, disposition: Self.makeSend)], body: Self.ndr + le(Status.ok))
            // The session ends with its last send right (the reply made one).
            _ = try host.requestNotification(session, id: ID.noSenders, sync: 1, notifyPort: session)
        } catch {
            log("scdynamicstore: configopen failed: \(error)")
            statusReply(m, Status.noStoreSession)
        }
    }

    private func endSession(_ session: UInt32) {
        let kept = lock.withLock { sessions.removeValue(forKey: session) }
        guard let kept else { return }
        for name in kept { try? host.deallocate(name) }
        try? host.removeMember(session, from: portSet)
        try? host.modRefs(session, right: Self.portReceive, delta: -1)
    }

    // MARK: Snapshot (snapshot.md §2.6)

    /// The service's state for a snapshot: one entry per open session (the
    /// session port and the notify rights it keeps, host-task names). The
    /// store itself is empty, so this is all of it.
    public var snapshotSessions: [(session: UInt32, notify: [UInt32])] {
        lock.withLock { sessions.sorted { $0.key < $1.key }.map { ($0.key, $0.value) } }
    }

    /// After a restore: the host task holds the recorded session ports
    /// (receive rights, members of the service's port set) and notify
    /// rights under their recorded names again; the service serves them.
    /// A session port that is not a member of the set any more is added.
    public func restoreSessions(_ list: [(session: UInt32, notify: [UInt32])]) {
        lock.withLock { for (session, notify) in list { sessions[session] = notify } }
        for (session, _) in list { try? host.addMember(session, to: portSet) }
    }

    /// The store's contents (§7). Tests replace it.
    nonisolated(unsafe) static var storeOverride: [String: Any]?
    static func store() -> [String: Any] { storeOverride ?? SCDynamicStoreNetworkState.current() }

    /// The bytes of the request's `index`th out-of-line descriptor.
    private func oolData(_ m: MachHostReceivedMessage, _ index: Int) -> [UInt8]? {
        let ool = m.descriptors.compactMap { d -> [UInt8]? in
            if case let .ool(data, _, _) = d { return data }
            return nil
        }
        return index < ool.count ? ool[index] : nil
    }

    // MARK: Replies

    private func statusReply(_ m: MachHostReceivedMessage, _ status: Int32) {
        reply(m, body: Self.ndr + le(0) + le(status))  // RetCode, status
    }

    private func reply(_ m: MachHostReceivedMessage, descriptors: [MachHostDescriptor] = [], body: [UInt8]) {
        do {
            try host.reply(to: m, descriptors: descriptors, body: body)
        } catch {
            log("scdynamicstore: reply to id \(m.id) failed: \(error)")
        }
    }

    /// Drops the rights a request brought (other than its reply right).
    private func dropRights(_ m: MachHostReceivedMessage) {
        for d in m.descriptors {
            switch d {
            case let .port(name, _), let .guardedPort(name, _, _): try? host.deallocate(name)
            case let .oolPorts(names, _): for n in names { try? host.deallocate(n) }
            case .ool: break
            }
        }
    }

    private func le(_ v: Int32) -> [UInt8] {
        let u = UInt32(bitPattern: v)
        return [UInt8(u & 0xFF), UInt8((u >> 8) & 0xFF), UInt8((u >> 16) & 0xFF), UInt8(u >> 24)]
    }

    /// An empty CFArray, serialized as a binary property list.
    static let emptyArrayPlist: [UInt8] = {
        let data = (try? PropertyListSerialization.data(fromPropertyList: [Any](), format: .binary, options: 0)) ?? Data()
        return [UInt8](data)
    }()
}

/// Host services that need no other configuration, started for every device
/// boot and registered into the guest by the control session
/// (`DeviceSession.hostServices`). Each entry is (name, host send right).
public enum DefaultHostServices {
    /// Starts each service that is not disabled (SCDynamicStore, power
    /// management, audio) and returns its names and send rights. A service
    /// that cannot start is logged as a warning and left out.
    public static func start(host: MachHostTask, log: @escaping (String) -> Void) -> [(name: String, port: UInt32)] {
        var out: [(name: String, port: UInt32)] = []
        if !SCDynamicStoreHostService.disabled {
            do {
                let s = try SCDynamicStoreHostService(host: host, log: log)
                s.start()
                running.append(s)
                for name in SCDynamicStoreHostService.serviceNames { out.append((name, s.servicePort)) }
            } catch {
                log("warning: cannot start the SCDynamicStore host service: \(error)")
            }
        }
        if !PowerManagementHostService.disabled {
            do {
                let s = try PowerManagementHostService(host: host, log: log)
                s.start()
                powerManagement = s
                out.append((PowerManagementHostService.serviceName, s.servicePort))
            } catch {
                log("warning: cannot start the power-management host service: \(error)")
            }
        }
        if !AudioHostService.disabled {
            do {
                let s = try AudioHostService(host: host, log: log)
                s.start()
                audio = s
                out.append((AudioHostService.serviceName, s.servicePort))
            } catch {
                log("warning: cannot start the audio host service: \(error)")
            }
        }
        return out
    }

    /// The audio service of this run, if it started (audio-host.md).
    nonisolated(unsafe) public private(set) static var audio: AudioHostService?

    /// The file-event service (fsevents-host.md), started by the device
    /// session with the device's configuration: (name, host send right), or
    /// nil when it is disabled or cannot start.
    public static func startFileEvents(host: MachHostTask, configuration: FSEventsHostService.Configuration,
                                       log: @escaping (String) -> Void) -> (name: String, port: UInt32)? {
        guard !FSEventsHostService.disabled else { return nil }
        do {
            let s = try FSEventsHostService(host: host, configuration: configuration, log: log)
            s.start()
            fsEvents = s
            return (FSEventsHostService.serviceName, s.servicePort)
        } catch {
            log("warning: cannot start the file-event host service: \(error)")
            return nil
        }
    }

    /// The file-event service of this run, if it started (snapshots).
    nonisolated(unsafe) public private(set) static var fsEvents: FSEventsHostService?

    nonisolated(unsafe) private static var running: [SCDynamicStoreHostService] = []
    /// The power-management service of this run, if it started (stateless:
    /// nothing to snapshot).
    nonisolated(unsafe) public private(set) static var powerManagement: PowerManagementHostService?

    /// The SCDynamicStore service of this run, if it started (snapshots).
    public static var scDynamicStore: SCDynamicStoreHostService? { running.first }
}
