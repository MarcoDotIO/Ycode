// ycode-simd --device: the host bootstrap server (stage4c-contract.md §3,
// §8.2 row V; specs/simulator/bootstrap-wire.md §5, §7, §8). A host thread
// receives on the host bootstrap port (a port of the VMM's host task, agent
// M's `MachHostTask`), logs every message (header, ids, descriptors, body
// bytes, the sender's audit token, and the decoded pipe dictionary), and
// answers:
//
// - `launchd_sim`'s startup request: `msgh_id` 708, 24 bytes, not complex
//   (bootstrap-wire.md §5.1). The host makes a port, keeps a send right to
//   it (the host end of the control channel), and replies `msgh_id` 808,
//   complex, 40 bytes, one port descriptor moving the receive right, no NDR
//   (§5.2).
// - pipe routines (`0x40000000 | n`, §2): 207 → `{error: 1102}`, 804 →
//   `{error: 3}` (no host names yet), 206 and 805 → `{port: receive right}`
//   (a new port), anything else → `{error: 45}`; reply id `0x20000000`.
// - one-way pipe messages (`0x10000000`) and anything else are logged and
//   dropped.
//
// `--debug-bootstrap-discard` restores the 4c-i behavior: log and drop,
// answer nothing.

#if os(Linux) && arch(arm64)
import Foundation
import Glibc
import YcodeDarwinABI
import YcodeDarwinKernel
import YcodeHypervisor
import YcodeXPC

final class HostBootstrapLogger: @unchecked Sendable {
    /// The host-task name of the control channel's send right (708), once given.
    private(set) var controlChannel: UInt32?
    /// Names checked in (206/805) and the host-task port each got (statistics).
    private(set) var checkIns: [(name: String, routine: Int)] = []
    let host: MachHostTask
    let logPath: String
    let discard: Bool
    private let lock = HostMutex()
    private var stopping = false
    private var thread = pthread_t()
    private var started = false
    private var logFile: UnsafeMutablePointer<FILE>?
    private(set) var count = 0
    /// Called (on the service thread) with the control channel's host-task
    /// name right after the 808 reply.
    var onControlChannel: ((UInt32) -> Void)?
    /// Called with the new service port's host-task name before the 808
    /// reply moves its receive right to launchd_sim (701s queued there are
    /// answered once the domains exist; launch-sim-control.md §5.1).
    var beforeServicePortHandoff: ((UInt32) -> Void)?

    init(host: MachHostTask, logPath: String, discard: Bool) {
        self.host = host
        self.logPath = logPath
        self.discard = discard
    }

    /// Starts the receiving thread.
    func start() throws {
        logFile = fopen(logPath, "w")
        if logFile == nil { stderrLine("ycode-simd: warning: cannot write \(logPath): \(String(cString: strerror(errno)))") }
        emit("host bootstrap service: receiving on host-task port \(hex(UInt64(host.bootstrapPort)))"
            + (discard ? " (log only: requests are dropped)" : " (serving 708 and pipe routines)"))
        let box = Unmanaged.passRetained(self).toOpaque()
        let result = pthread_create(&thread, nil, { argument in
            let logger = Unmanaged<HostBootstrapLogger>.fromOpaque(argument!).takeRetainedValue()
            logger.run()
            return nil
        }, box)
        guard result == 0 else {
            Unmanaged<HostBootstrapLogger>.fromOpaque(box).release()
            throw KVMError("pthread_create (host bootstrap service)", errno: result)
        }
        started = true
    }

    /// Stops the thread (it notices within one receive timeout) and joins it.
    func stop() {
        lock.withLock { stopping = true }
        if started { pthread_join(thread, nil); started = false }
        emit("host bootstrap service: stopped after \(count) messages")
        if let logFile { fclose(logFile) }
        logFile = nil
    }

    private var isStopping: Bool { lock.withLock { stopping } }

    private func run() {
        while !isStopping {
            let message: MachHostReceivedMessage
            do {
                message = try host.receive(on: host.bootstrapPort, timeout: 100_000_000, tracked: true)
            } catch let error as MachHostError where error == .timedOut || error == .interrupted {
                continue
            } catch {
                emit("host bootstrap service: receive failed: \(error); stopping")
                return
            }
            count += 1
            emit(Self.describe(message, number: count))
            if discard { host.discard(message) } else { serve(message) }
            host.finishedMessage()
        }
    }

    // MARK: Serving

    private func serve(_ m: MachHostReceivedMessage) {
        let id = UInt32(bitPattern: m.id)
        do {
            if m.id == XPCBootstrap.launchdSimServiceRequestID && m.size == 24 && !m.isComplex {
                try serveServicePortRequest(m)
            } else if id & 0xF000_0000 == 0x4000_0000 {
                try servePipeRoutine(m, routine: Int(id & 0x0FFF_FFFF))
            } else if id & 0xF000_0000 == 0x1000_0000 {
                emit("  one-way pipe message: dropped")
                dropRights(of: m, includingReply: true)
            } else {
                emit("  unknown request id \(m.id): dropped (no reply)")
                dropRights(of: m, includingReply: true)
            }
        } catch {
            emit("  reply failed: \(error)")
            dropRights(of: m, includingReply: true)
        }
    }

    /// bootstrap-wire.md §5.2: a new port; the receive right goes to the
    /// requester, the host keeps a send right (the control channel).
    private func serveServicePortRequest(_ m: MachHostReceivedMessage) throws {
        let port = try host.makePort(sendRight: true)
        beforeServicePortHandoff?(port)
        do {
            try host.reply(to: m, id: XPCBootstrap.launchdSimServiceReplyID, descriptors: [.port(name: port, disposition: MachMsgType.moveReceive)], body: [])
        } catch {
            try? host.destroyPort(port)
            throw error
        }
        if let old = controlChannel { try? host.deallocate(old) }
        controlChannel = port
        emit("  -> 808: service port (receive right) given; host keeps the control-channel send right \(hex(UInt64(port)))")
        onControlChannel?(port)
    }

    /// bootstrap-wire.md §2, §4.2, §8 item 1 (decoding and replies: `YcodeXPC`).
    private func servePipeRoutine(_ m: MachHostReceivedMessage, routine: Int) throws {
        let wire: [XPCWireDescriptor] = m.descriptors.map {
            switch $0 {
            case let .port(name, type): return .port(name: name, disposition: type)
            case let .ool(data, _, _): return .ool(bytes: data)
            case let .oolPorts(names, type): return .oolPorts(names: names, disposition: type)
            case let .guardedPort(name, _, type): return .guardedPort(name: name, disposition: type)
            }
        }
        let request: XPCPipeRequest?
        do {
            request = try XPCPipeRequest(msghID: m.id, body: m.body, descriptors: wire,
                                         hasReplyPort: m.replyPort != 0 && m.replyPort != 0xFFFF_FFFF)
            emit("  \(request!)")
        } catch {
            request = nil
            emit("  pipe routine \(routine): cannot decode the payload: \(error)")
        }
        let name = request?.name
        var reply: XPCPipeMessage
        var newPort: UInt32?
        switch routine {
        case _ where request == nil:
            reply = XPCPipeReply.error(XPCBootstrapError.unsupported)
        case Int(XPCBootstrapRoutine.lookUp.rawValue):
            reply = XPCPipeReply.error(XPCBootstrapError.unknownService)
        case Int(XPCBootstrapRoutine.serviceLookUp.rawValue):
            reply = XPCPipeReply.error(XPCBootstrapError.esrch)
        case Int(XPCBootstrapRoutine.checkIn.rawValue), Int(XPCBootstrapRoutine.listenerCheckIn.rawValue):
            let port = try host.makePort()
            newPort = port
            reply = XPCPipeReply.receiveRight(port)
        default:
            reply = XPCPipeReply.error(XPCBootstrapError.unsupported)
        }
        let descriptors: [MachHostDescriptor] = reply.descriptors.map {
            switch $0 {
            case let .port(name, disposition), let .guardedPort(name, disposition): return .port(name: name, disposition: disposition)
            case let .ool(bytes): return .ool(data: bytes)
            case let .oolPorts(names, disposition): return .oolPorts(names: names, disposition: disposition)
            }
        }
        do {
            try host.reply(to: m, id: reply.msghID, descriptors: descriptors, body: reply.body)
        } catch {
            if let newPort { try? host.destroyPort(newPort) }
            throw error
        }
        if newPort != nil { lock.withLock { checkIns.append((name ?? "?", routine)) } }
        let summary = (try? reply.decodeDictionary()).map { "\($0)" } ?? "\(reply.body.count) bytes"
        emit("  -> \(hex(UInt64(reply.id))): \(summary)" + (name.map { " (name \"\($0)\")" } ?? ""))
        // The request's own rights (descriptors) are not kept; the reply right was used.
        dropRights(of: m, includingReply: false)
    }

    /// Drops the rights a received message brought.
    private func dropRights(of m: MachHostReceivedMessage, includingReply: Bool) {
        var copy = m
        if !includingReply { copy.replyPort = 0 }
        host.discard(copy)
    }

    /// One line per field group (the first line is the summary).
    static func describe(_ m: MachHostReceivedMessage, number: Int) -> String {
        func h32(_ v: UInt32) -> String { String(format: "0x%x", v) }
        var lines: [String] = []
        let sender = m.sender.map { "pid \($0.pid) (pidversion \($0.pidVersion), euid \($0.euid), egid \($0.egid), asid \($0.auditSessionID))" } ?? "the kernel"
        lines.append("host bootstrap message #\(number): id \(m.id) (\(h32(UInt32(bitPattern: m.id)))) from \(sender); "
            + "size \(m.size), \(m.descriptors.count) descriptors, \(m.body.count) body bytes")
        lines.append("  header: bits \(h32(m.bits)) (remote type \(m.bits & 0x1F), local type \((m.bits >> 8) & 0x1F), voucher type \((m.bits >> 16) & 0x1F)"
            + "\(m.isComplex ? ", complex" : "")); reply port \(h32(m.replyPort)) type \(m.replyType); local \(h32(m.localPort)); "
            + "voucher \(h32(m.voucher)); seqno \(m.seqno); context \(hex(m.context))")
        if let token = m.sender { lines.append("  audit token: " + token.words.map(h32).joined(separator: " ")) }
        for (i, d) in m.descriptors.enumerated() {
            switch d {
            case let .port(name, type):
                lines.append("  descriptor \(i): port \(h32(name)) type \(type)")
            case let .guardedPort(name, flags, type):
                lines.append("  descriptor \(i): guarded port \(h32(name)) flags \(h32(UInt32(flags))) type \(type)")
            case let .ool(data, copy, volatile):
                lines.append("  descriptor \(i): OOL \(data.count) bytes, copy \(copy)\(volatile ? ", volatile" : "")")
                lines += hexDump(data, indent: "    ")
            case let .oolPorts(names, type):
                lines.append("  descriptor \(i): OOL ports type \(type): " + names.map(h32).joined(separator: " "))
            }
        }
        lines.append("  body:")
        lines += hexDump(m.body, indent: "    ")
        return lines.joined(separator: "\n")
    }

    /// 16 bytes per line: offset, hex, printable ASCII.
    static func hexDump(_ bytes: [UInt8], indent: String) -> [String] {
        guard !bytes.isEmpty else { return [indent + "(empty)"] }
        var lines: [String] = []
        var offset = 0
        while offset < bytes.count {
            let row = bytes[offset..<min(offset + 16, bytes.count)]
            let hexPart = row.map { String(format: "%02x", $0) }.joined(separator: " ")
            let text = String(row.map { (0x20..<0x7F).contains($0) ? Character(UnicodeScalar($0)) : "." })
            lines.append(indent + String(format: "%04x  ", offset) + hexPart.padding(toLength: 47, withPad: " ", startingAt: 0) + "  " + text)
            offset += 16
        }
        return lines
    }

    private func emit(_ text: String) {
        stderrLine("ycode-simd: " + text)
        lock.withLock {
            if let logFile {
                fputs(text + "\n", logFile)
                fflush(logFile)
            }
        }
    }
}
#endif
