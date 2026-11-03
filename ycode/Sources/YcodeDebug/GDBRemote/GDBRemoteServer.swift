import Foundation

// Ycode's gdb-remote stub: one client connection, one process at a time,
// all-stop (`specs/simulator/debug-stub.md` §3–§6). Packet set and reply
// shapes: GDB's remote protocol documentation and LLDB's
// `lldbgdbremote.md` (level 1). The host and process are protocols
// (`GDBRemoteTarget.swift`), so the protocol logic runs and is tested
// without a simulator.

/// The byte pipe of one client.
public protocol GDBRemoteConnection: AnyObject {
    /// Blocks for the next bytes; nil or empty at the end of the stream.
    func receive() -> [UInt8]?
    func send(_ bytes: [UInt8])
    func close()
}

public final class GDBRemoteServer: @unchecked Sendable {
    public let host: GDBRemoteHost
    /// Called with each packet and reply, for `--debug-server-log`.
    public var log: ((String) -> Void)?

    private let connection: GDBRemoteConnection
    private var decoder = GDBRemoteDecoder()
    private var acks = true
    private var errorStrings = false
    private let sendLock = NSLock()
    private let stateLock = NSLock()

    // Session state (connection thread, or under `stateLock` while running).
    private var process: GDBRemoteProcess?
    private var layout = GDBRemoteARM64Layout(floatingPoint: false)
    private var running = false
    private var registerThread: UInt64?
    private var continueThread: UInt64?
    /// The thread of the last stop.
    private var stopThread: UInt64?
    private var threadListCursor = 0
    private var savedStates: [Int: (UInt64, GDBRemoteThreadRegisters)] = [:]
    private var nextSaveID = 1
    private var waiter: Thread?
    /// The process ended while the client was attached; its last status.
    private var exitReply: String?

    public init(host: GDBRemoteHost, connection: GDBRemoteConnection) {
        self.host = host
        self.connection = connection
    }

    // MARK: Serving

    /// Serves the connection until the client goes away. Detaches from the
    /// process at the end (the process keeps running).
    public func serve() {
        // The host's process is attached at the first packet, so a
        // connection that sends nothing (a port probe) stops nothing.
        var first = true
        while let bytes = connection.receive(), !bytes.isEmpty {
            for input in decoder.append(bytes) {
                switch input {
                case let .packet(body):
                    if first {
                        first = false
                        if process == nil, let p = host.initialProcess() { adopt(p) }
                    }
                    if acks { connection.send([UInt8(ascii: "+")]) }
                    handle(body: body)
                case .badChecksum:
                    if acks { connection.send([UInt8(ascii: "-")]) }
                case .interrupt:
                    log?("<- ^C")
                    if isRunning { process?.interrupt() }
                case .ack, .nack:
                    break
                }
            }
        }
        // The client is gone: let the process run on.
        if let p = process {
            if isRunning {
                p.interrupt()
                while isRunning { usleep(1000) }
            }
            if process != nil {
                p.breakpoints.removeAll()
                p.detach()
                process = nil
            }
        }
        connection.close()
    }

    private var isRunning: Bool { stateLock.withLockFallback { running } }

    private func adopt(_ p: GDBRemoteProcess) {
        process = p
        layout = GDBRemoteARM64Layout(floatingPoint: p.hasFloatingPointRegisters)
        stopThread = p.threadIDs().first(where: { p.stopInfo($0).reason != .none }) ?? p.threadIDs().first
        registerThread = nil
        continueThread = nil
        exitReply = nil
    }

    private func reply(_ text: String) {
        log?("-> " + (text.count > 400 ? String(text.prefix(400)) + "…" : text))
        sendLock.withLockFallback { connection.send(GDBRemoteFraming.frame(text)) }
    }

    private func reply(bytes: [UInt8]) {
        log?("-> <\(bytes.count) binary bytes>")
        sendLock.withLockFallback { connection.send(GDBRemoteFraming.frame(bytes)) }
    }

    private func error(_ code: UInt8, _ message: String) -> String {
        let e = "E" + GDBRemoteHex.encode([code])
        return errorStrings ? e + ";" + GDBRemoteHex.encode(text: message) : e
    }

    private func error(_ e: GDBRemoteError) -> String { error(e.code, e.message) }

    // MARK: Dispatch

    /// Handles one packet body (unescaped bytes). `X` carries binary data,
    /// so it is decoded before the body becomes text.
    func handle(body: [UInt8]) {
        if body.first == UInt8(ascii: "X") {
            log?("<- X… (\(body.count) bytes)")
            reply(binaryWrite(body))
            return
        }
        handle(String(decoding: body, as: UTF8.self))
    }

    /// `X<addr>,<length>:<binary>`.
    func binaryWrite(_ body: [UInt8]) -> String {
        if isRunning { return error(0x10, "the process is running") }
        guard let p = process, let colon = body.firstIndex(of: UInt8(ascii: ":")),
              let (address, count) = Self.addressAndLength(String(decoding: body[1..<colon], as: UTF8.self)) else {
            return error(0x16, "bad memory write")
        }
        let bytes = Array(body[(colon + 1)...])
        if count == 0 { return "OK" }
        guard bytes.count == count else { return error(0x16, "bad memory write length") }
        return p.breakpoints.writeThrough(address, bytes) ? "OK" : error(0x0E, "cannot write memory")
    }

    /// Handles one packet and sends its reply (none for a resume: the stop
    /// reply follows when the process stops).
    func handle(_ packet: String) {
        log?("<- " + (packet.count > 200 ? String(packet.prefix(200)) + "…" : packet))
        if let text = respond(packet) { reply(text) }
    }

    /// The reply to one packet; nil when it is sent later (resume) or was
    /// sent already (binary).
    func respond(_ packet: String) -> String? {
        if isRunning {
            // All-stop: only an interrupt makes sense while running.
            return error(0x10, "the process is running")
        }
        let (command, threadSuffix) = Self.splitThreadSuffix(packet)
        switch true {
        case command == "QStartNoAckMode":
            reply("OK")
            acks = false
            return nil
        case command.hasPrefix("qSupported"):
            return "PacketSize=20000;QStartNoAckMode+;QThreadSuffixSupported+;QListThreadsInStopReply+;qEcho+;vContSupported+;qXfer:features:read-;multiprocess-"
        case command == "QThreadSuffixSupported", command == "QListThreadsInStopReply", command == "qVAttachOrWaitSupported",
             command.hasPrefix("QSetDetachOnError"), command.hasPrefix("QSetDisableASLR"), command == "QSetIgnoredExceptions",
             command.hasPrefix("QSetIgnoredExceptions:"):
            return "OK"
        case command == "QEnableErrorStrings":
            errorStrings = true
            return "OK"
        case command == "qHostInfo":
            return host.hostInfo.map { "\($0.0):\($0.1);" }.joined()
        case command == "qGDBServerVersion":
            return "name:ycode-simd;version:1;"
        case command == "qProcessInfo":
            guard let p = process else { return error(0x01, "no process") }
            return "pid:\(String(p.pid, radix: 16));" + p.processInfo.map { "\($0.0):\($0.1);" }.joined()
        case command.hasPrefix("qProcessInfoPID:"):
            guard let pid = Int(command.dropFirst("qProcessInfoPID:".count)),
                  let entry = host.processes().first(where: { $0.pid == pid }) else { return error(0x01, "no such process") }
            return "pid:\(String(pid, radix: 16));name:\(GDBRemoteHex.encode(text: entry.name));"
        case command.hasPrefix("qfProcessInfo"):
            threadListCursor = 0
            return processListReply()
        case command.hasPrefix("qsProcessInfo"):
            return processListReply()
        case command == "qC":
            // No process yet: thread 0, which LLDB takes as "connected, no
            // process" (as debugserver answers before a launch or attach).
            guard let p = process else { return "QC0" }
            return "QC" + String(stopThread ?? p.threadIDs().first ?? 0, radix: 16)
        case command == "qAttached":
            return process == nil ? error(0x01, "no process") : "1"
        case command == "?":
            // No process yet: an error (as debugserver answers), so the
            // client stays connected and attaches later.
            guard let p = process else { return exitReply ?? error(0x02, "no process") }
            let tid = stopThread ?? p.threadIDs().first ?? 0
            return stopReply(p, thread: tid)
        case command == "qfThreadInfo":
            // No process: an error. An empty list ("l") made LLDB assume a
            // bare-board target with pid 1.
            guard let p = process else { return error(0x02, "no process") }
            return "m" + p.threadIDs().map { String($0, radix: 16) }.joined(separator: ",")
        case command == "qsThreadInfo":
            return "l"
        case command.hasPrefix("qThreadStopInfo"):
            guard let p = process, let tid = GDBRemoteHex.number(command.dropFirst("qThreadStopInfo".count)),
                  p.threadIDs().contains(tid) else { return error(0x01, "no such thread") }
            return stopReply(p, thread: tid)
        case command.hasPrefix("qThreadExtraInfo,"):
            guard let p = process, let tid = GDBRemoteHex.number(command.dropFirst("qThreadExtraInfo,".count)) else { return error(0x01, "no such thread") }
            return GDBRemoteHex.encode(text: p.threadName(tid) ?? "")
        case command == "jThreadsInfo":
            guard let p = process else { return error(0x01, "no process") }
            return threadsInfoJSON(p)
        case command.hasPrefix("T") && command.count > 1:
            guard let p = process, let tid = GDBRemoteHex.number(command.dropFirst()) else { return error(0x01, "no such thread") }
            return p.threadIDs().contains(tid) ? "OK" : error(0x01, "no such thread")
        case command.hasPrefix("qRegisterInfo"):
            guard let n = Int(command.dropFirst("qRegisterInfo".count), radix: 16), let r = layout.register(n) else { return error(0x45, "no such register") }
            return r.infoReply
        case command == "qShlibInfoAddr":
            guard let a = process?.sharedLibraryInfoAddress else { return error(0x01, "no image list") }
            return String(a, radix: 16)
        case command.hasPrefix("qMemoryRegionInfo"):
            return memoryRegionReply(command)
        case command.hasPrefix("qWatchpointSupportInfo"):
            return "num:\(process?.watchpointSlots ?? 0);"
        case command.hasPrefix("qSymbol"):
            return "OK"
        case command.hasPrefix("qEcho:"):
            return String(command.dropFirst("qEcho:".count))
        case command.hasPrefix("H"):
            return selectThread(command)
        case command == "g":
            return withThread(threadSuffix) { p, tid in
                guard let r = p.registers(tid) else { return error(0x01, "cannot read the registers") }
                return GDBRemoteHex.encode(layout.block(of: r))
            }
        case command.hasPrefix("G"):
            return withThread(threadSuffix) { p, tid in
                guard let bytes = GDBRemoteHex.decode(String(command.dropFirst())), let base = p.registers(tid),
                      let state = layout.state(fromBlock: bytes, base: base) else { return error(0x16, "bad register block") }
                return p.setRegisters(tid, state) ? "OK" : error(0x01, "cannot write the registers")
            }
        case command.hasPrefix("p"):
            return withThread(threadSuffix) { p, tid in
                guard let n = Int(command.dropFirst(), radix: 16), layout.register(n) != nil else { return error(0x45, "no such register") }
                guard let r = p.registers(tid), let bytes = layout.bytes(of: n, in: r) else { return error(0x01, "cannot read the register") }
                return GDBRemoteHex.encode(bytes)
            }
        case command.hasPrefix("P"):
            return withThread(threadSuffix) { p, tid in
                let body = command.dropFirst()
                guard let eq = body.firstIndex(of: "="), let n = Int(body[..<eq], radix: 16),
                      let bytes = GDBRemoteHex.decode(String(body[body.index(after: eq)...])), var r = p.registers(tid),
                      layout.set(n, bytes: bytes, in: &r) else { return error(0x45, "bad register write") }
                return p.setRegisters(tid, r) ? "OK" : error(0x01, "cannot write the register")
            }
        case command.hasPrefix("QSaveRegisterState"):
            return withThread(threadSuffix) { p, tid in
                guard let r = p.registers(tid) else { return error(0x01, "cannot read the registers") }
                let id = nextSaveID
                nextSaveID += 1
                savedStates[id] = (tid, r)
                return String(id)
            }
        case command.hasPrefix("QRestoreRegisterState:"):
            return withThread(threadSuffix) { p, tid in
                guard let id = Int(command.dropFirst("QRestoreRegisterState:".count)), let (owner, r) = savedStates.removeValue(forKey: id) else {
                    return error(0x01, "no such saved state")
                }
                return p.setRegisters(owner == tid ? tid : owner, r) ? "OK" : error(0x01, "cannot restore the registers")
            }
        case command.hasPrefix("m"):
            guard let p = process, let (address, count) = Self.addressAndLength(command.dropFirst()) else { return error(0x16, "bad memory read") }
            let bytes = p.breakpoints.shadow(address, p.readMemory(address, count: count))
            return bytes.isEmpty && count > 0 ? error(0x0E, "cannot read memory") : GDBRemoteHex.encode(bytes)
        case command.hasPrefix("x"):
            guard let p = process, let (address, count) = Self.addressAndLength(command.dropFirst()) else { return error(0x16, "bad memory read") }
            if count == 0 { return "OK" }
            let bytes = p.breakpoints.shadow(address, p.readMemory(address, count: count))
            if bytes.isEmpty { return error(0x0E, "cannot read memory") }
            reply(bytes: bytes)
            return nil
        case command.hasPrefix("M"):
            guard let p = process, let colon = command.firstIndex(of: ":"),
                  let (address, count) = Self.addressAndLength(command[command.index(after: command.startIndex)..<colon]),
                  let bytes = GDBRemoteHex.decode(String(command[command.index(after: colon)...])), bytes.count == count else {
                return error(0x16, "bad memory write")
            }
            return p.breakpoints.writeThrough(address, bytes) ? "OK" : error(0x0E, "cannot write memory")
        case command.hasPrefix("X"):
            return binaryWrite(Array(packet.utf8))
        case command.hasPrefix("Z0,"), command.hasPrefix("z0,"):
            guard let p = process else { return error(0x01, "no process") }
            let fields = command.dropFirst(3).split(separator: ",")
            guard let first = fields.first, let address = GDBRemoteHex.number(first) else { return error(0x16, "bad breakpoint") }
            let result = command.hasPrefix("Z") ? p.breakpoints.insert(address) : p.breakpoints.remove(address)
            switch result {
            case .success: return "OK"
            case let .failure(e): return error(e)
            }
        case command.hasPrefix("Z2,"), command.hasPrefix("Z3,"), command.hasPrefix("Z4,"),
             command.hasPrefix("z2,"), command.hasPrefix("z3,"), command.hasPrefix("z4,"):
            return watchpoint(command)
        case command.hasPrefix("Z"), command.hasPrefix("z"):
            return ""   // hardware breakpoints: not offered
        case command == "vCont?":
            return "vCont;c;C;s;S"
        case command.hasPrefix("vCont;"):
            return resume(vCont: String(command.dropFirst("vCont;".count)))
        case command.hasPrefix("c"), command.hasPrefix("C"), command.hasPrefix("s"), command.hasPrefix("S"):
            return resume(legacy: command)
        case command.hasPrefix("vAttachWait;"), command.hasPrefix("vAttachOrWait;"), command.hasPrefix("vAttachName;"), command.hasPrefix("vAttach;"):
            return attach(command)
        case command == "D" || command.hasPrefix("D;") || command == "D1":
            guard let p = process else { return "OK" }
            p.breakpoints.removeAll()
            p.detach()
            process = nil
            return "OK"
        case command == "k" || command.hasPrefix("vKill"):
            guard let p = process else { return "X09" }
            p.breakpoints.forgetAll()
            p.kill()
            process = nil
            exitReply = "X09"
            return "X09"
        case command == "jGetSharedCacheInfo:", command == "jGetLoadedDynamicLibrariesInfos:":
            return "OK"   // the client's support probe
        case command.hasPrefix("jGetLoadedDynamicLibrariesInfos:"):
            return loadedImagesReply(String(command.dropFirst("jGetLoadedDynamicLibrariesInfos:".count)))
        case command == "jGetDyldProcessState":
            guard let p = process else { return error(0x01, "no process") }
            guard let state = p.dyldState else { return error(0x01, "dyld's state is not known") }
            return state.reply
        case command.hasPrefix("jGetSharedCacheInfo"):
            guard let p = process else { return error(0x01, "no process") }
            guard let info = p.sharedCacheInfo, info.uuid.count == 16 else {
                return "{\"no_shared_cache\":true}"
            }
            return "{\"shared_cache_base_address\":\(info.base),\"shared_cache_uuid\":\"\(Self.uuidString(info.uuid))\","
                + "\"no_shared_cache\":false,\"shared_cache_private_cache\":false}"
        case command.hasPrefix("_M"):
            // `_M<size>,<permissions>` → the address (hex). LLDB needs it:
            // without it, it calls mmap in the process to get memory.
            guard let p = process else { return error(0x01, "no process") }
            let parts = command.dropFirst(2).split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)
            guard let first = parts.first, let size = GDBRemoteHex.number(first), size > 0, size <= 1 << 30 else { return error(0x16, "bad allocation") }
            let perms = parts.count > 1 ? String(parts[1]) : "rw"
            guard let a = p.allocateMemory(size: size, permissions: perms) else { return error(0x0C, "cannot allocate memory") }
            return String(a, radix: 16)
        case command.hasPrefix("_m"):
            guard let p = process, let a = GDBRemoteHex.number(command.dropFirst(2)) else { return error(0x16, "bad address") }
            return p.deallocateMemory(a) ? "OK" : error(0x16, "not allocated by the debugger")
        case command.hasPrefix("qXfer"), command.hasPrefix("vFile"), command.hasPrefix("j"), command.hasPrefix("q"), command.hasPrefix("Q"),
             command.hasPrefix("v"), command.hasPrefix("A"):
            return ""   // not supported: the empty reply
        default:
            return ""
        }
    }

    // MARK: Packets in detail

    /// `p…;thread:<tid>;` → ("p…", tid).
    static func splitThreadSuffix(_ packet: String) -> (String, UInt64?) {
        guard let r = packet.range(of: ";thread:", options: .backwards), !packet.hasPrefix("vCont") else { return (packet, nil) }
        var tail = packet[r.upperBound...]
        if tail.hasSuffix(";") { tail = tail.dropLast() }
        guard let tid = GDBRemoteHex.number(tail) else { return (packet, nil) }
        return (String(packet[..<r.lowerBound]), tid)
    }

    /// `<addr>,<length>` in hex.
    static func addressAndLength<S: StringProtocol>(_ text: S) -> (UInt64, Int)? {
        let parts = text.split(separator: ",", maxSplits: 1)
        guard parts.count == 2, let a = GDBRemoteHex.number(parts[0]), let n = GDBRemoteHex.number(parts[1]), n <= 1 << 20 else { return nil }
        return (a, Int(n))
    }

    private func withThread(_ suffix: UInt64?, _ body: (GDBRemoteProcess, UInt64) -> String) -> String {
        guard let p = process else { return error(0x01, "no process") }
        let threads = p.threadIDs()
        var tid = suffix ?? registerThread ?? stopThread ?? threads.first ?? 0
        if tid == 0 || tid == UInt64.max { tid = stopThread ?? threads.first ?? 0 }
        guard threads.contains(tid) else { return error(0x01, "no such thread") }
        return body(p, tid)
    }

    private func selectThread(_ command: String) -> String {
        guard command.count >= 2 else { return error(0x16, "bad thread selection") }
        let kind = command[command.index(after: command.startIndex)]
        guard let tid = GDBRemoteHex.number(command.dropFirst(2)) else { return error(0x16, "bad thread id") }
        let value: UInt64? = (tid == 0 || tid == UInt64.max) ? nil : tid
        if let value, let p = process, !p.threadIDs().contains(value) { return error(0x01, "no such thread") }
        if kind == "g" { registerThread = value } else { continueThread = value }
        return "OK"
    }

    private func processListReply() -> String {
        let list = host.processes()
        guard threadListCursor < list.count else { return error(0x03, "no more processes") }
        let e = list[threadListCursor]
        threadListCursor += 1
        return "pid:\(String(e.pid, radix: 16));name:\(GDBRemoteHex.encode(text: e.name));"
    }

    private func memoryRegionReply(_ command: String) -> String {
        guard let p = process, let address = GDBRemoteHex.number(command.dropFirst("qMemoryRegionInfo:".count)) else {
            return error(0x01, "no process")
        }
        guard let r = p.memoryRegion(at: address) else { return error(0x01, "no region information") }
        var s = "start:\(String(r.start, radix: 16));size:\(String(r.size, radix: 16));"
        if let perms = r.permissions { s += "permissions:\(perms);" }
        if let name = r.name { s += "name:\(GDBRemoteHex.encode(text: name));" }
        return s
    }

    /// `jGetLoadedDynamicLibrariesInfos:<json>` (debug-stub.md §4.3).
    func loadedImagesReply(_ arguments: String) -> String {
        guard let p = process else { return error(0x01, "no process") }
        guard let request = GDBRemoteImageRequest.parse(arguments) else { return error(0x16, "bad image request") }
        guard let list = p.loadedImages() else { return error(0x01, "no image list") }
        let read = { (a: UInt64, n: Int) in p.breakpoints.shadow(a, p.readMemory(a, count: n)) }
        var wanted: [(address: UInt64, path: String)]
        switch request.selection {
        case .all:
            wanted = list
        case let .addresses(addresses):
            var paths: [UInt64: String] = [:]
            for e in list where paths[e.address] == nil { paths[e.address] = e.path }
            wanted = addresses.map { ($0, paths[$0] ?? "") }
        case let .list(address, count):
            // `dyld_image_info` = {imageLoadAddress, imageFilePath, imageFileModDate}.
            let bytes = read(address, 24 * count)
            wanted = stride(from: 0, to: bytes.count / 24 * 24, by: 24).map { o in
                let a = GDBRemoteMachO.u64(bytes, o), pathAddress = GDBRemoteMachO.u64(bytes, o + 8)
                return (a, Self.cString(at: pathAddress, read: read))
            }
        }
        if request.detail == .addressOnly {
            return GDBRemoteImageInfo.reply(wanted.map {
                GDBRemoteImageInfo(loadAddress: $0.address, path: $0.path, uuid: nil, magic: 0, cputype: 0, cpusubtype: 0, filetype: 0,
                                   flags: 0, headerAndCommandsSize: 0, segments: [])
            }, .addressOnly)
        }
        // Images whose header cannot be read are left out (as debugserver does).
        let images = wanted.compactMap { GDBRemoteMachO.image(at: $0.address, path: $0.path, read: read) }
        return GDBRemoteImageInfo.reply(images, request.detail)
    }

    /// A NUL-terminated string of the process (1 KiB at most).
    public static func cString(at address: UInt64, read: (UInt64, Int) -> [UInt8]) -> String {
        guard address != 0 else { return "" }
        var out: [UInt8] = []
        var cursor = address
        while out.count < 1024 {
            // Up to the end of the 256-byte block, so no read crosses into an unmapped page needlessly.
            let chunk = read(cursor, Int(256 - (cursor & 255)))
            if chunk.isEmpty { break }
            if let nul = chunk.firstIndex(of: 0) { out += chunk[..<nul]; break }
            out += chunk
            cursor &+= UInt64(chunk.count)
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// `Z2,<addr>,<size>` … `z4,…`: hardware watchpoints.
    private func watchpoint(_ command: String) -> String {
        guard let p = process else { return error(0x01, "no process") }
        let insert = command.hasPrefix("Z")
        let fields = command.dropFirst(3).split(separator: ",")
        guard let kind = GDBRemoteWatchKind(rawValue: Int(String(command.dropFirst().prefix(1))) ?? 0), fields.count >= 2,
              let address = GDBRemoteHex.number(fields[0]), let size = GDBRemoteHex.number(fields[1]), size > 0, size <= 1 << 31 else {
            return error(0x16, "bad watchpoint")
        }
        let result = insert ? p.insertWatchpoint(address: address, size: Int(size), kind: kind)
            : p.removeWatchpoint(address: address, size: Int(size), kind: kind)
        switch result {
        case .success: return "OK"
        case let .failure(e): return error(e)
        }
    }

    private func attach(_ command: String) -> String {
        if process != nil { return error(0x01, "already attached") }
        let result: Result<GDBRemoteProcess, GDBRemoteError>
        if command.hasPrefix("vAttach;") {
            guard let pid = GDBRemoteHex.number(command.dropFirst("vAttach;".count)) else { return error(0x16, "bad pid") }
            result = host.attach(pid: Int(pid))
        } else {
            let wait = command.hasPrefix("vAttachWait;") || command.hasPrefix("vAttachOrWait;")
            guard let semicolon = command.firstIndex(of: ";"),
                  let name = GDBRemoteHex.decodeText(String(command[command.index(after: semicolon)...])) else {
                return error(0x16, "bad name")
            }
            result = host.attach(name: name, wait: wait, includeExisting: command.hasPrefix("vAttachOrWait;"))
        }
        switch result {
        case let .success(p):
            adopt(p)
            let tid = stopThread ?? p.threadIDs().first ?? 0
            return stopReply(p, thread: tid)
        case let .failure(e):
            return error(e)
        }
    }

    // MARK: Resuming

    private func resume(legacy command: String) -> String? {
        guard let p = process else { return error(0x01, "no process") }
        let step = command.hasPrefix("s") || command.hasPrefix("S")
        var signal: Int?
        var rest = command.dropFirst()
        if command.hasPrefix("C") || command.hasPrefix("S") {
            let parts = rest.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
            signal = parts.first.flatMap { Int($0, radix: 16) }
            rest = parts.count > 1 ? parts[1] : ""
        }
        let tid = continueThread ?? stopThread ?? p.threadIDs().first ?? 0
        if let address = GDBRemoteHex.number(rest), !rest.isEmpty, var r = p.registers(tid) {
            r.pc = address
            _ = p.setRegisters(tid, r)
        }
        if step { return start(p, [tid: .step(signal: signal)], others: .stop) }
        // `c` continues every thread; the signal goes to the selected one.
        return start(p, [tid: .continue(signal: signal)], others: .continue(signal: nil))
    }

    /// `vCont;<action>[:<tid>];…` — the first action that names a thread
    /// applies to it; an action without a thread applies to the others.
    private func resume(vCont text: String) -> String? {
        guard let p = process else { return error(0x01, "no process") }
        var actions: [UInt64: GDBRemoteResume] = [:]
        var others = GDBRemoteResume.stop
        for item in text.split(separator: ";") {
            let parts = item.split(separator: ":", maxSplits: 1)
            guard let a = parts.first, let action = Self.action(a) else { return error(0x16, "bad vCont action \(item)") }
            if parts.count == 2 {
                guard let tid = GDBRemoteHex.number(parts[1]) else { return error(0x16, "bad vCont thread") }
                if tid == UInt64.max || tid == 0 {
                    if others == .stop { others = action }
                } else if actions[tid] == nil {
                    actions[tid] = action
                }
            } else if others == .stop {
                others = action
            }
        }
        return start(p, actions, others: others)
    }

    static func action<S: StringProtocol>(_ text: S) -> GDBRemoteResume? {
        guard let kind = text.first else { return nil }
        let sig = text.count > 1 ? Int(text.dropFirst(), radix: 16) : nil
        switch kind {
        case "c": return .continue(signal: nil)
        case "C": return sig.map { .continue(signal: $0) }
        case "s": return .step(signal: nil)
        case "S": return sig.map { .step(signal: $0) }
        case "t": return .stop
        default: return nil
        }
    }

    private func start(_ p: GDBRemoteProcess, _ actions: [UInt64: GDBRemoteResume], others: GDBRemoteResume) -> String? {
        switch p.resume(actions, others: others) {
        case let .failure(e): return error(e)
        case .success: break
        }
        stateLock.withLockFallback { running = true }
        let t = Thread { [self] in
            let event = p.waitForEvent()
            let text: String
            switch event {
            case let .stopped(thread):
                stopThread = thread
                registerThread = nil
                text = stopReply(p, thread: thread)
            case let .exited(status):
                text = "W" + GDBRemoteHex.encode([UInt8(truncatingIfNeeded: status)])
                p.breakpoints.forgetAll()
                process = nil
                exitReply = text
            case let .terminated(signal):
                text = "X" + GDBRemoteHex.encode([UInt8(truncatingIfNeeded: signal)])
                p.breakpoints.forgetAll()
                process = nil
                exitReply = text
            }
            stateLock.withLockFallback { running = false }
            reply(text)
        }
        t.name = "ycode debug stub: wait"
        waiter = t
        t.start()
        return nil
    }

    // MARK: Stop replies

    /// The `T` packet for `thread` (LLDB's extended form).
    func stopReply(_ p: GDBRemoteProcess, thread tid: UInt64) -> String {
        let info = p.stopInfo(tid)
        let threads = p.threadIDs()
        var s = "T" + GDBRemoteHex.encode([UInt8(truncatingIfNeeded: info.signal)])
        s += "thread:\(String(tid, radix: 16));"
        if let name = p.threadName(tid), !name.isEmpty { s += "hexname:\(GDBRemoteHex.encode(text: name));" }
        if let q = p.dispatchQueueAddress(tid) { s += "qaddr:\(String(q, radix: 16));" }
        s += "threads:" + threads.map { String($0, radix: 16) }.joined(separator: ",") + ";"
        let pcs = threads.map { t in p.registers(t).map { String($0.pc, radix: 16) } ?? "0" }
        s += "thread-pcs:" + pcs.joined(separator: ",") + ";"
        if let r = p.registers(tid) {
            for n in GDBRemoteARM64Layout.expedited {
                if let bytes = layout.bytes(of: n, in: r) { s += GDBRemoteHex.encode([UInt8(n)]) + ":" + GDBRemoteHex.encode(bytes) + ";" }
            }
        }
        s += Self.reasonFields(info.reason)
        return s
    }

    static func reasonFields(_ reason: GDBRemoteStopReason) -> String {
        switch reason {
        case .none: ""
        case .signal: ""   // the signal alone (SIGSTOP for an interrupt or an attach)
        case .breakpoint: "reason:breakpoint;"
        case .trace: "reason:trace;"
        case let .exception(text): "reason:exception;description:\(GDBRemoteHex.encode(text: text));"
        case let .watchpoint(address, index, hit):
            // "<address in the watched range> <register> <reported address>",
            // decimal (lldbgdbremote.md, `reason:watchpoint`).
            "reason:watchpoint;description:\(GDBRemoteHex.encode(text: "\(address) \(index) \(hit)"));"
        }
    }

    /// `jThreadsInfo`: one JSON object per thread.
    func threadsInfoJSON(_ p: GDBRemoteProcess) -> String {
        var items: [String] = []
        for tid in p.threadIDs() {
            let info = p.stopInfo(tid)
            var fields = ["\"tid\":\(tid)"]
            if let name = p.threadName(tid), !name.isEmpty { fields.append("\"name\":\(Self.jsonString(name))") }
            if let q = p.dispatchQueueAddress(tid) { fields.append("\"qaddr\":\(q)") }
            fields.append("\"signal\":\(info.signal)")
            switch info.reason {
            case .none: break
            case .signal: break
            case .breakpoint: fields.append("\"reason\":\"breakpoint\"")
            case .trace: fields.append("\"reason\":\"trace\"")
            case let .exception(text):
                fields.append("\"reason\":\"exception\"")
                fields.append("\"description\":\(Self.jsonString(text))")
            case let .watchpoint(address, index, hit):
                fields.append("\"reason\":\"watchpoint\"")
                fields.append("\"description\":\(Self.jsonString("\(address) \(index) \(hit)"))")
            }
            if let r = p.registers(tid) {
                let regs = GDBRemoteARM64Layout.expedited.compactMap { n in
                    layout.bytes(of: n, in: r).map { "\"\(n)\":\"\(GDBRemoteHex.encode($0))\"" }
                }
                fields.append("\"registers\":{" + regs.joined(separator: ",") + "}")
            }
            items.append("{" + fields.joined(separator: ",") + "}")
        }
        return "[" + items.joined(separator: ",") + "]"
    }

    /// 16 bytes as `XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX`.
    static func uuidString(_ b: [UInt8]) -> String {
        let h = GDBRemoteHex.encode(b).uppercased()
        let c = Array(h)
        return [0..<8, 8..<12, 12..<16, 16..<20, 20..<32].map { String(c[$0]) }.joined(separator: "-")
    }

    static func jsonString(_ s: String) -> String {
        var out = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if u.value < 0x20 { out += String(format: "\\u%04x", u.value) } else { out.unicodeScalars.append(u) }
            }
        }
        return out + "\""
    }
}

extension NSLock {
    /// `withLock` on every Foundation this package builds with.
    @inline(__always) func withLockFallback<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
