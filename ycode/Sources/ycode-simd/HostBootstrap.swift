// ycode-simd --device: the logging host bootstrap service (stage4c-contract.md
// §3, §4 row V). A host thread receives on the host bootstrap port (a port
// of the VMM's host task, agent M's `MachHostTask`) and prints every message:
// header, ids, descriptors, body bytes, and the sender's audit token. Phase
// 4c-i replies to nothing: by default the requests (and their reply rights)
// are kept, so a sender waiting for a reply keeps waiting;
// `--debug-bootstrap-discard` drops them instead (the sender then gets a
// send-once notification on its reply port).

#if os(Linux) && arch(arm64)
import Foundation
import Glibc
import YcodeDarwinABI
import YcodeDarwinKernel
import YcodeHypervisor

final class HostBootstrapLogger: @unchecked Sendable {
    let host: MachHostTask
    let logPath: String
    let discard: Bool
    private let lock = HostMutex()
    private var stopping = false
    private var thread = pthread_t()
    private var started = false
    private var logFile: UnsafeMutablePointer<FILE>?
    /// Messages kept unanswered (their rights stay in the host task).
    private(set) var kept: [MachHostReceivedMessage] = []
    private(set) var count = 0

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
            + (discard ? " (requests are discarded)" : " (requests are kept unanswered)"))
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
                message = try host.receive(on: host.bootstrapPort, timeout: 100_000_000)
            } catch let error as MachHostError where error == .timedOut || error == .interrupted {
                continue
            } catch {
                emit("host bootstrap service: receive failed: \(error); stopping")
                return
            }
            count += 1
            emit(Self.describe(message, number: count))
            if discard { host.discard(message) } else { lock.withLock { kept.append(message) } }
        }
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
