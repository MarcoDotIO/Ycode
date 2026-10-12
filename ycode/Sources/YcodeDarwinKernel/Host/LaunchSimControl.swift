// The host end of launchd_sim's control channel
// (specs/simulator/launch-sim-control.md; stage7-contract.md §3.2 item 1).
// After the 708 → 808 exchange the host keeps a send right to launchd_sim's
// service port. This client sends the MIG requests of subsystem 700 on it:
// 700 bind, 701 register, 702 find, 703 getenv, 704 spawn, 705 waitpid,
// 709 unregister. It never sends any other id (launch-sim-control.md §5.5:
// with AbortOnUnknownIPC, launchd_sim kills the sender of an unknown id).
//
// Each request is a routine with its own reply port (a receive right of the
// host task, MAKE_SEND_ONCE in the request), so a blocking 705 does not
// hold up other requests. Replies: `msgh_id` = request + 100; RetCode at
// body offset 8 (after NDR) of a non-complex reply is read first; an errno
// `e` arrives as `0xC000 | e` (§2.2, §2.3).

import Foundation

/// A failed control request: `code` is the reply's RetCode (with
/// `0xC000 | e` decoded to `errno`), or a Mach send/receive error.
public struct LaunchSimControlError: Error, CustomStringConvertible {
    public var operation: String
    public var code: UInt32
    public var errno: Int32? { code & 0xFFFF_C000 == 0xC000 ? Int32(code & 0x3FFF) : nil }
    public init(operation: String, code: UInt32) {
        self.operation = operation
        self.code = code
    }
    public var description: String {
        if let errno { return "\(operation): errno \(errno) (\(String(cString: strerror(errno))))" }
        return "\(operation): 0x\(String(code, radix: 16))"
    }
}

/// The spawn attributes of a 704 request (launch-sim-control.md §4).
public struct LaunchSimSpawnAttributes {
    public var path: String
    public var argv: [String]
    public var environment: [String] = []
    public var workingDirectory: String?
    /// CPU type preference (0 = none); subtype is always "any".
    public var cpuType: UInt32 = 0
    public var startSuspended = false

    public init(path: String, argv: [String], environment: [String] = [], workingDirectory: String? = nil,
                cpuType: UInt32 = 0, startSuspended: Bool = false) {
        self.path = path
        self.argv = argv
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.cpuType = cpuType
        self.startSuspended = startSuspended
    }

    /// The OOL blob: 39 header words, then the string region (path, argv,
    /// environment, working directory, binary preference), packed, no
    /// trailing padding. Offsets in the header are relative to the region.
    public var blob: [UInt8] {
        var region: [UInt8] = []
        func add(_ s: String) -> UInt32 {
            let at = UInt32(region.count)
            region += Array(s.utf8) + [0]
            return at
        }
        var words = [UInt32](repeating: 0, count: 39)
        _ = add(path)  // word 1: the path is always at region offset 0
        if !argv.isEmpty {
            words[2] = UInt32(argv.count)
            words[3] = UInt32(region.count)
            for a in argv { _ = add(a) }
        }
        if !environment.isEmpty {
            words[4] = UInt32(environment.count)
            words[5] = UInt32(region.count)
            for e in environment { _ = add(e) }
        }
        if let workingDirectory { words[14] = add(workingDirectory) }
        if cpuType != 0 {
            words[6] = 1
            words[7] = UInt32(region.count)
            region += le32(cpuType) + le32(0xFFFF_FFFF)
        }
        words[23] = startSuspended ? 1 : 0
        words[24] = 0x400
        words[0] = UInt32(156 + region.count)
        return words.flatMap { le32($0) } + region
    }
}

public final class LaunchSimControl: @unchecked Sendable {
    public static let bind: Int32 = 700, register: Int32 = 701, find: Int32 = 702, getenv: Int32 = 703
    public static let spawn: Int32 = 704, waitpid: Int32 = 705, unregister: Int32 = 709

    public let host: MachHostTask
    /// The host task's send right to launchd_sim's service port.
    public let channel: UInt32
    private let log: (String) -> Void
    private let lock = NSLock()
    /// The session port's receive right (700); destroyed to shut the guest down.
    private var sessionPort: UInt32?

    public init(host: MachHostTask, channel: UInt32, log: @escaping (String) -> Void) {
        self.host = host
        self.channel = channel
        self.log = log
    }

    private static let ndr: [UInt8] = [0, 0, 0, 0, 1, 0, 0, 0]

    /// `name128`: at most 127 bytes, NUL-padded to 128.
    private static func name128(_ s: String) -> [UInt8] {
        let bytes = Array(s.utf8.prefix(127))
        return bytes + [UInt8](repeating: 0, count: 128 - bytes.count)
    }

    /// One routine: sends, waits for the reply (nil = forever), returns it.
    private func call(_ id: Int32, _ operation: String, descriptors: [MachHostDescriptor] = [], body: [UInt8] = [],
                      timeout: UInt64? = 30_000_000_000) throws -> MachHostReceivedMessage {
        let reply = try host.makePort()
        defer { try? host.destroyPort(reply) }
        do {
            try host.send(MachHostOutgoingMessage(remotePort: channel, remoteDisposition: MachMsgType.copySend,
                                                  localPort: reply, localDisposition: MachMsgType.makeSendOnce,
                                                  id: id, descriptors: descriptors, body: body), timeout: 5_000_000_000)
        } catch let e as MachHostError {
            throw LaunchSimControlError(operation: operation, code: e.code)
        }
        let m: MachHostReceivedMessage
        do {
            m = try host.receive(on: reply, timeout: timeout)
        } catch let e as MachHostError {
            throw LaunchSimControlError(operation: operation, code: e.code)
        }
        guard m.id == id + 100 else {
            host.discard(m)
            throw LaunchSimControlError(operation: operation + " (reply id \(m.id))", code: MachKern.failure)
        }
        if !m.isComplex, m.body.count >= 12 {
            let code = m.body.readLE(UInt32.self, at: 8)
            if code != 0 {
                host.discard(m)
                throw LaunchSimControlError(operation: operation, code: code)
            }
        }
        return m
    }

    // MARK: Operations

    /// 700: binds the session to a new port whose receive right the host keeps.
    public func bindSession() throws {
        let port = try host.makePort(sendRight: true)
        do {
            _ = try call(Self.bind, "bind", descriptors: [.port(name: port, disposition: MachMsgType.makeSend)])
        } catch {
            try? host.destroyPort(port)
            throw error
        }
        lock.withLock { sessionPort = port }
        log("control: 700 bind: session port 0x\(String(port, radix: 16))")
    }

    /// 701: makes `name` a host-side endpoint of `user/<uid>` sending to `port`
    /// (a right of the host task; the host keeps its own).
    public func registerEndpoint(_ name: String, port: UInt32) throws {
        _ = try call(Self.register, "register \(name)", descriptors: [.port(name: port, disposition: MachMsgType.copySend)],
                     body: Self.ndr + Self.name128(name))
    }

    /// 709.
    public func unregisterEndpoint(_ name: String) throws {
        _ = try call(Self.unregister, "unregister \(name)", body: Self.ndr + Self.name128(name))
    }

    /// 702: a send right (host-task name) to a `user/<uid>` endpoint.
    public func findEndpoint(_ name: String) throws -> UInt32 {
        let m = try call(Self.find, "find \(name)", body: Self.ndr + Self.name128(name))
        guard case let .port(port, _)? = m.descriptors.first else {
            host.discard(m)
            throw LaunchSimControlError(operation: "find \(name)", code: MachKern.failure)
        }
        return port
    }

    /// 703: a variable of the `user/<uid>` domain environment (nil if unset).
    public func domainEnvironment(_ name: String) throws -> String? {
        do {
            let m = try call(Self.getenv, "getenv \(name)", body: Self.ndr + Self.name128(name))
            let value = m.body.count >= 12 ? Array(m.body[12...].prefix(128)) : []
            return String(decoding: value.prefix { $0 != 0 }, as: UTF8.self)
        } catch let e as LaunchSimControlError where e.errno == 3 {
            return nil
        }
    }

    /// 704: a one-shot program; the stdio ports are host-task fileport send
    /// rights (moved to launchd_sim) or 0. Returns the pid.
    public func spawn(_ attributes: LaunchSimSpawnAttributes, stdin: UInt32, stdout: UInt32, stderr: UInt32) throws -> Int32 {
        let blob = attributes.blob
        let ports = [stdin, stdout, stderr].map { MachHostDescriptor.port(name: $0, disposition: MachMsgType.moveSend) }
        let m = try call(Self.spawn, "spawn \(attributes.path)", descriptors: [.ool(data: blob, copy: 1)] + ports,
                         body: Self.ndr + le32(UInt32(blob.count)))
        guard m.body.count >= 16 else { throw LaunchSimControlError(operation: "spawn", code: MachKern.failure) }
        return Int32(bitPattern: m.body.readLE(UInt32.self, at: 12))
    }

    /// 705: the wait status of a one-shot (blocks until it exits, or `timeout`).
    public func waitpid(_ pid: Int32, timeout: UInt64? = nil) throws -> Int32 {
        let m = try call(Self.waitpid, "waitpid \(pid)", body: Self.ndr + le32(UInt32(bitPattern: pid)), timeout: timeout)
        guard m.body.count >= 16 else { throw LaunchSimControlError(operation: "waitpid", code: MachKern.failure) }
        return Int32(bitPattern: m.body.readLE(UInt32.self, at: 12))
    }

    /// Destroys the session port's receive right: launchd_sim shuts the
    /// guest down and exits 0 (launch-sim-control.md §3.1).
    public func endSession() {
        guard let port = lock.withLock({ () -> UInt32? in defer { sessionPort = nil }; return sessionPort }) else { return }
        try? host.destroyPort(port)
        log("control: session port destroyed (guest shutdown requested)")
    }

    public var isBound: Bool { lock.withLock { sessionPort != nil } }
}
