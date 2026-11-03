import Foundation
import Testing
@testable import YcodeDebug

// The gdb-remote stub's protocol layer (specs/simulator/debug-stub.md):
// framing, hex, the arm64 register layout, the breakpoint table, and the
// server's packets against a scripted process.

// MARK: Test doubles

final class FakeConnection: GDBRemoteConnection, @unchecked Sendable {
    private let lock = NSLock()
    private var sent: [[UInt8]] = []
    private var inbox: [[UInt8]] = []
    private let available = DispatchSemaphore(value: 0)

    func receive() -> [UInt8]? {
        available.wait()
        return lock.withLockFallback { inbox.isEmpty ? nil : inbox.removeFirst() }
    }

    func feed(_ text: String) {
        lock.withLockFallback { inbox.append(Array(text.utf8)) }
        available.signal()
    }

    func send(_ bytes: [UInt8]) { lock.withLockFallback { sent.append(bytes) } }
    func close() {}

    /// The bodies of the packets sent so far (acks dropped).
    var replies: [String] {
        lock.withLockFallback {
            var d = GDBRemoteDecoder()
            return sent.flatMap { d.append($0) }.compactMap { if case let .packet(b) = $0 { String(decoding: b, as: UTF8.self) } else { nil } }
        }
    }

    func waitForReplies(_ n: Int) -> [String] {
        for _ in 0..<2000 where replies.count < n { usleep(1000) }
        return replies
    }
}

final class FakeProcess: GDBRemoteProcess, @unchecked Sendable {
    var memory: [UInt64: UInt8] = [:]
    var regs: [UInt64: GDBRemoteThreadRegisters] = [:]
    var stops: [UInt64: GDBRemoteThreadStop] = [:]
    var lastResume: ([UInt64: GDBRemoteResume], GDBRemoteResume)?
    var detached = false, killed = false, interrupted = false
    let events = DispatchSemaphore(value: 0)
    var nextEvent = GDBRemoteEvent.stopped(thread: 0x101)
    lazy var breakpoints = GDBRemoteBreakpoints(read: { [unowned self] a, n in readMemory(a, count: n) },
                                                write: { [unowned self] a, b in writeMemory(a, bytes: b) })

    init() {
        var main = GDBRemoteThreadRegisters()
        main.pc = 0x1_0000_4000
        main.sp = 0x16_f000_0000
        main.x[29] = 0x16_f000_0010
        main.x[30] = 0x1_0000_5000
        main.cpsr = 0x6000_0000
        regs[0x101] = main
        regs[0x102] = GDBRemoteThreadRegisters(pc: 0x1_8000_0000)
        for i in 0..<64 { memory[0x1_0000_4000 + UInt64(i)] = UInt8(i) }
    }

    var pid: Int { 0x2a }
    var processInfo: [(String, String)] { [("cputype", "100000c"), ("ostype", "iossimulator")] }
    var sharedLibraryInfoAddress: UInt64? { 0x3_1000_8100 }
    var hasFloatingPointRegisters: Bool { false }
    var sharedCacheInfo: (base: UInt64, uuid: [UInt8])? { (0x1_C000_0000, Array(0..<16)) }
    func threadIDs() -> [UInt64] { regs.keys.sorted() }
    func threadName(_ tid: UInt64) -> String? { tid == 0x101 ? "main;thread" : nil }
    func dispatchQueueAddress(_ tid: UInt64) -> UInt64? { tid == 0x101 ? 0x2000 : nil }
    func stopInfo(_ tid: UInt64) -> GDBRemoteThreadStop { stops[tid] ?? .quiet }
    func registers(_ tid: UInt64) -> GDBRemoteThreadRegisters? { regs[tid] }
    func setRegisters(_ tid: UInt64, _ r: GDBRemoteThreadRegisters) -> Bool { regs[tid] = r; return true }
    func readMemory(_ address: UInt64, count: Int) -> [UInt8] {
        var out: [UInt8] = []
        for i in 0..<count {
            guard let b = memory[address + UInt64(i)] else { break }
            out.append(b)
        }
        return out
    }
    func writeMemory(_ address: UInt64, bytes: [UInt8]) -> Bool {
        for (i, b) in bytes.enumerated() {
            guard memory[address + UInt64(i)] != nil else { return false }
            memory[address + UInt64(i)] = b
        }
        return true
    }
    func memoryRegion(at address: UInt64) -> GDBRemoteMemoryRegion? {
        address >= 0x1_0000_4000 && address < 0x1_0000_8000
            ? GDBRemoteMemoryRegion(start: 0x1_0000_4000, size: 0x4000, permissions: "rx", name: "/app/Demo")
            : GDBRemoteMemoryRegion(start: 0, size: 0x1_0000_4000, permissions: nil)
    }
    var allocations: [UInt64: (UInt64, String)] = [:]
    func allocateMemory(size: UInt64, permissions: String) -> UInt64? {
        let a = 0x2_0000_0000 + UInt64(allocations.count) * 0x4000
        allocations[a] = (size, permissions)
        return a
    }
    func deallocateMemory(_ address: UInt64) -> Bool { allocations.removeValue(forKey: address) != nil }
    func resume(_ actions: [UInt64: GDBRemoteResume], others: GDBRemoteResume) -> Result<Void, GDBRemoteError> {
        lastResume = (actions, others)
        return .success(())
    }
    func interrupt() { interrupted = true; events.signal() }
    func waitForEvent() -> GDBRemoteEvent {
        events.wait()
        return nextEvent
    }
    func detach() { detached = true }
    func kill() { killed = true }

    // Images and watchpoints (off unless a test sets them).
    var images: [(address: UInt64, path: String)]?
    var state: GDBRemoteDyldState?
    var slots = 0
    var watches: [(UInt64, Int, GDBRemoteWatchKind)] = []
    func loadedImages() -> [(address: UInt64, path: String)]? { images }
    var dyldState: GDBRemoteDyldState? { state }
    var watchpointSlots: Int { slots }
    func insertWatchpoint(address: UInt64, size: Int, kind: GDBRemoteWatchKind) -> Result<Void, GDBRemoteError> {
        guard watches.count < slots else { return .failure(GDBRemoteError(0x1C, "no free hardware watchpoint")) }
        watches.append((address, size, kind))
        return .success(())
    }
    func removeWatchpoint(address: UInt64, size: Int, kind: GDBRemoteWatchKind) -> Result<Void, GDBRemoteError> {
        watches.removeAll { $0.0 == address && $0.1 == size && $0.2 == kind }
        return .success(())
    }
}

final class FakeHost: GDBRemoteHost, @unchecked Sendable {
    let process = FakeProcess()
    var attachAtConnect = true
    var hostInfo: [(String, String)] { [("cputype", "16777228"), ("ostype", "iossimulator"), ("vendor", "apple")] }
    func initialProcess() -> GDBRemoteProcess? { attachAtConnect ? process : nil }
    func attach(pid: Int) -> Result<GDBRemoteProcess, GDBRemoteError> {
        pid == 0x2a ? .success(process) : .failure(GDBRemoteError(1, "no process \(pid)"))
    }
    func attach(name: String, wait: Bool, includeExisting: Bool) -> Result<GDBRemoteProcess, GDBRemoteError> {
        name == "Demo" ? .success(process) : .failure(GDBRemoteError(1, "no process"))
    }
    func processes() -> [(pid: Int, name: String)] { [(0x2a, "Demo")] }
}

/// A server whose session is attached to `host.process`.
private func attachedServer() -> (GDBRemoteServer, FakeHost, FakeConnection) {
    let host = FakeHost()
    let c = FakeConnection()
    let s = GDBRemoteServer(host: host, connection: c)
    #expect(s.respond("vAttach;2a")?.hasPrefix("T") == true)
    return (s, host, c)
}

// MARK: Framing and hex

@Suite struct GDBRemoteFramingTests {
    @Test func framesWithTheChecksum() {
        #expect(String(decoding: GDBRemoteFraming.frame("OK"), as: UTF8.self) == "$OK#9a")
        #expect(String(decoding: GDBRemoteFraming.frame(""), as: UTF8.self) == "$#00")
        // `}`, `#`, `$` and `*` are escaped (XOR 0x20) and the checksum covers the escaped bytes.
        let framed = GDBRemoteFraming.frame([0x7D, 0x23, 0x24, 0x2A, 0x41])
        #expect(Array(framed.dropFirst().prefix(9)) == [0x7D, 0x5D, 0x7D, 0x03, 0x7D, 0x04, 0x7D, 0x0A, 0x41])
        let sum = GDBRemoteFraming.checksum([0x7D, 0x5D, 0x7D, 0x03, 0x7D, 0x04, 0x7D, 0x0A, 0x41])
        #expect(Array(framed.suffix(2)) == [GDBRemoteHex.digit(sum >> 4), GDBRemoteHex.digit(sum & 0xF)])
    }

    @Test func decodesPacketsAcksAndInterrupts() {
        var d = GDBRemoteDecoder()
        let out = d.append(Array("+$qC#b4-\u{03}$m10,4#2e".utf8))
        #expect(out == [.ack, .packet(Array("qC".utf8)), .nack, .interrupt, .packet(Array("m10,4".utf8))])
    }

    @Test func decodesAcrossReadsAndRejectsBadChecksums() {
        var d = GDBRemoteDecoder()
        #expect(d.append(Array("$qSupp".utf8)).isEmpty)
        #expect(d.append(Array("orted#3".utf8)).isEmpty)
        #expect(d.append(Array("7".utf8)) == [.packet(Array("qSupported".utf8))])
        #expect(d.append(Array("$OK#00".utf8)) == [.badChecksum])
    }

    @Test func takesAnUnescapedClosingBrace() {
        // LLDB sends `jGetSharedCacheInfo:{}` without escaping the last `}`.
        var d = GDBRemoteDecoder()
        let body = Array("jGetSharedCacheInfo:{}".utf8)
        let sum = GDBRemoteFraming.checksum(body)
        let raw = [UInt8(ascii: "$")] + body + [UInt8(ascii: "#"), GDBRemoteHex.digit(sum >> 4), GDBRemoteHex.digit(sum & 0xF)]
        #expect(d.append(raw + Array("$qC#b4".utf8)) == [.packet(body), .packet(Array("qC".utf8))])
        // An escaped `#` (`}` 0x03) inside a body still decodes as one.
        #expect(d.append(GDBRemoteFraming.frame([0x41, 0x23, 0x42])) == [.packet([0x41, 0x23, 0x42])])
    }

    @Test func unescapesBinaryBodies() {
        var d = GDBRemoteDecoder()
        let framed = GDBRemoteFraming.frame([0x58, 0x7D, 0x23, 0x00, 0xFF])
        #expect(d.append(framed) == [.packet([0x58, 0x7D, 0x23, 0x00, 0xFF])])
    }

    @Test func hexHelpers() {
        #expect(GDBRemoteHex.encode([0x00, 0xAB, 0x7F]) == "00ab7f")
        #expect(GDBRemoteHex.decode("00AB7f") == [0x00, 0xAB, 0x7F])
        #expect(GDBRemoteHex.decode("0") == nil)
        #expect(GDBRemoteHex.decode("zz") == nil)
        #expect(GDBRemoteHex.number("-1") == UInt64.max)
        #expect(GDBRemoteHex.number("1a2b") == 0x1A2B)
        #expect(GDBRemoteHex.littleEndian(0x1122, size: 4) == "22110000")
        #expect(GDBRemoteHex.decodeText(GDBRemoteHex.encode(text: "DebugDemo")) == "DebugDemo")
    }
}

// MARK: Registers

@Suite struct GDBRemoteRegisterTests {
    @Test func generalPurposeLayout() {
        let l = GDBRemoteARM64Layout(floatingPoint: false)
        #expect(l.registers.count == 34)
        #expect(l.blockSize == 33 * 8 + 4)
        #expect(l.register(29)?.name == "fp")
        #expect(l.register(30)?.generic == "ra")
        #expect(l.register(31)?.name == "sp")
        #expect(l.register(33)?.size == 4)
        #expect(l.register(32)?.infoReply
                == "name:pc;bitsize:64;offset:256;encoding:uint;format:hex;set:General Purpose Registers;ehframe:32;dwarf:32;generic:pc;")
        #expect(l.register(0)?.infoReply.contains("generic:arg1;") == true)
        #expect(l.register(29)?.infoReply.contains("alt-name:x29;") == true)
        #expect(l.register(34) == nil)
    }

    @Test func floatingPointLayout() {
        let l = GDBRemoteARM64Layout(floatingPoint: true)
        #expect(l.registers.count == 68)
        #expect(l.blockSize == 33 * 8 + 4 + 32 * 16 + 8)
        #expect(l.register(34)?.name == "v0")
        #expect(l.register(34)?.offset == 268)
        #expect(l.register(34)?.dwarf == 64)
        #expect(l.register(34)?.infoReply.contains("encoding:vector;format:vector-uint8;") == true)
        #expect(l.register(67)?.name == "fpcr")
    }

    @Test func blockRoundTrip() {
        let l = GDBRemoteARM64Layout(floatingPoint: false)
        var r = GDBRemoteThreadRegisters()
        for i in 0..<31 { r.x[i] = UInt64(i) * 0x0101_0101 }
        r.sp = 0x16_F000_0000
        r.pc = 0x1_0000_4004
        r.cpsr = 0x2000_0000
        let block = l.block(of: r)
        #expect(block.count == l.blockSize)
        #expect(Array(block[256..<264]) == [0x04, 0x40, 0x00, 0x00, 0x01, 0, 0, 0])
        #expect(l.state(fromBlock: block, base: GDBRemoteThreadRegisters()) == r)
        #expect(l.state(fromBlock: Array(block.dropLast()), base: r) == nil)
        var s = r
        #expect(l.set(32, bytes: [0x08, 0x40, 0, 0, 1, 0, 0, 0], in: &s))
        #expect(s.pc == 0x1_0000_4008)
        #expect(!l.set(32, bytes: [1, 2], in: &s))
    }
}

// MARK: Breakpoints

@Suite struct GDBRemoteBreakpointTests {
    @Test func insertShadowRemove() {
        let p = FakeProcess()
        let bp = p.breakpoints
        let a: UInt64 = 0x1_0000_4008
        #expect(throws: Never.self) { try bp.insert(a).get() }
        #expect(p.readMemory(a, count: 4) == GDBRemoteBreakpoints.instructionBytes)
        #expect(GDBRemoteHex.littleEndianValue(GDBRemoteBreakpoints.instructionBytes) == UInt64(GDBRemoteBreakpoints.instruction))
        // Reads see the original bytes, also when they cover part of it.
        #expect(bp.shadow(a - 2, p.readMemory(a - 2, count: 8)) == [6, 7, 8, 9, 10, 11, 12, 13])
        #expect(bp.shadow(a + 2, p.readMemory(a + 2, count: 1)) == [10])
        // Inserting twice keeps the first original bytes.
        #expect(throws: Never.self) { try bp.insert(a).get() }
        #expect(bp.contains(a))
        #expect(throws: Never.self) { try bp.remove(a).get() }
        #expect(p.readMemory(a, count: 4) == [8, 9, 10, 11])
        #expect(!bp.contains(a))
    }

    @Test func writesOverABreakpointKeepIt() {
        let p = FakeProcess()
        let bp = p.breakpoints
        let a: UInt64 = 0x1_0000_4010
        #expect(throws: Never.self) { try bp.insert(a).get() }
        #expect(bp.writeThrough(a - 1, [0xAA, 0xBB, 0xCC]))
        #expect(p.readMemory(a - 1, count: 5) == [0xAA, 0x00, 0x00, 0x3E, 0xD4])
        #expect(bp.shadow(a - 1, p.readMemory(a - 1, count: 5)) == [0xAA, 0xBB, 0xCC, 18, 19])
        #expect(throws: Never.self) { try bp.remove(a).get() }
        #expect(p.readMemory(a, count: 4) == [0xBB, 0xCC, 18, 19])
    }

    @Test func refusesMisalignedAndUnmapped() {
        let p = FakeProcess()
        #expect(throws: GDBRemoteError.self) { try p.breakpoints.insert(0x1_0000_4002).get() }
        #expect(throws: GDBRemoteError.self) { try p.breakpoints.insert(0x9_0000_0000).get() }
        p.breakpoints.removeAll()
    }
}

// MARK: The server

@Suite struct GDBRemoteServerTests {
    @Test func handshake() {
        let (s, _, _) = attachedServer()
        #expect(s.respond("qSupported:xmlRegisters=i386,arm,mips")?.contains("QStartNoAckMode+") == true)
        #expect(s.respond("QThreadSuffixSupported") == "OK")
        #expect(s.respond("QListThreadsInStopReply") == "OK")
        #expect(s.respond("qHostInfo") == "cputype:16777228;ostype:iossimulator;vendor:apple;")
        #expect(s.respond("qProcessInfo") == "pid:2a;cputype:100000c;ostype:iossimulator;")
        #expect(s.respond("qShlibInfoAddr") == "310008100")
        #expect(s.respond("vCont?") == "vCont;c;C;s;S")
        #expect(s.respond("qWatchpointSupportInfo:") == "num:0;")
        // The clients' support probes (an empty argument) answer OK.
        #expect(s.respond("jGetLoadedDynamicLibrariesInfos:") == "OK")
        #expect(s.respond("jGetSharedCacheInfo:") == "OK")
        // This process offers no image list and no dyld state.
        #expect(s.respond("jGetLoadedDynamicLibrariesInfos:{\"fetch_all_solibs\":true}")?.hasPrefix("E") == true)
        #expect(s.respond("jGetDyldProcessState")?.hasPrefix("E") == true)
        #expect(s.respond("jGetSharedCacheInfo:{}")
                == "{\"shared_cache_base_address\":7516192768,\"shared_cache_uuid\":\"00010203-0405-0607-0809-0A0B0C0D0E0F\",\"no_shared_cache\":false,\"shared_cache_private_cache\":false}")
        #expect(s.respond("qXfer:features:read:target.xml:0,1000") == "")
        #expect(s.respond("Z2,1000,4")?.hasPrefix("E") == true)
        #expect(s.respond("Z1,1000,4") == "")
    }

    @Test func memoryAllocation() {
        let (s, host, _) = attachedServer()
        #expect(s.respond("_M1000,rwx") == "200000000")
        #expect(host.process.allocations[0x2_0000_0000]! == (0x1000, "rwx"))
        #expect(s.respond("_M0,rw")?.hasPrefix("E") == true)
        #expect(s.respond("_m200000000") == "OK")
        #expect(s.respond("_m200000000")?.hasPrefix("E") == true)
    }

    @Test func noAckModeStopsAcknowledgements() {
        let host = FakeHost()
        let c = FakeConnection()
        let s = GDBRemoteServer(host: host, connection: c)
        let t = Thread { s.serve() }
        t.start()
        c.feed("+$QStartNoAckMode#b0")
        #expect(c.waitForReplies(1) == ["OK"])
        c.feed("$qC#b4")
        #expect(c.waitForReplies(2).last == "QC101")
        c.feed("")   // end of stream: the server detaches
        for _ in 0..<2000 where !host.process.detached { usleep(1000) }
        #expect(host.process.detached)
    }

    @Test func threadsAndStopReplies() {
        let (s, host, _) = attachedServer()
        host.process.stops[0x101] = GDBRemoteThreadStop(signal: 5, reason: .breakpoint)
        #expect(s.respond("qfThreadInfo") == "m101,102")
        #expect(s.respond("qsThreadInfo") == "l")
        #expect(s.respond("T102") == "OK")
        #expect(s.respond("T999")?.hasPrefix("E") == true)
        let t = s.respond("qThreadStopInfo101") ?? ""
        #expect(t.hasPrefix("T05thread:101;"))
        #expect(t.contains("hexname:\(GDBRemoteHex.encode(text: "main;thread"));"))
        #expect(t.contains("qaddr:2000;"))
        #expect(t.contains("threads:101,102;"))
        #expect(t.contains("thread-pcs:100004000,180000000;"))
        #expect(t.contains("20:0040000001000000;"))   // pc
        #expect(t.contains("21:00000060;"))           // cpsr
        #expect(t.hasSuffix("reason:breakpoint;"))
        host.process.stops[0x102] = GDBRemoteThreadStop(signal: 11, reason: .exception("SIGSEGV: bad access"))
        let u = s.respond("qThreadStopInfo102") ?? ""
        #expect(u.hasPrefix("T0bthread:102;"))
        #expect(u.hasSuffix("reason:exception;description:\(GDBRemoteHex.encode(text: "SIGSEGV: bad access"));"))
        let json = s.respond("jThreadsInfo") ?? ""
        #expect(json.hasPrefix("[{\"tid\":257,\"name\":\"main;thread\",\"qaddr\":8192,\"signal\":5,\"reason\":\"breakpoint\",\"registers\":{\"29\":"))
        #expect(json.contains("{\"tid\":258,\"signal\":11,\"reason\":\"exception\",\"description\":\"SIGSEGV: bad access\""))
    }

    @Test func registersWithTheThreadSuffix() {
        let (s, host, _) = attachedServer()
        #expect(s.respond("qRegisterInfo20")?.hasPrefix("name:pc;") == true)
        #expect(s.respond("qRegisterInfo22")?.hasPrefix("E") == true)
        #expect(s.respond("p20;thread:102;") == "0000008001000000")
        #expect(s.respond("p20") == "0040000001000000")
        #expect(s.respond("P20=0840000001000000;thread:101;") == "OK")
        #expect(host.process.regs[0x101]?.pc == 0x1_0000_4008)
        #expect(s.respond("Hg102") == "OK")
        #expect(s.respond("p1f") == GDBRemoteHex.littleEndian(0, size: 8))
        let g = s.respond("g;thread:101;") ?? ""
        #expect(g.count == 2 * (33 * 8 + 4))
        #expect(s.respond("G" + g + ";thread:102;") == "OK")
        #expect(host.process.regs[0x102]?.pc == 0x1_0000_4008)
        let id = s.respond("QSaveRegisterState;thread:101;") ?? ""
        #expect(s.respond("P20=0000000000000000;thread:101;") == "OK")
        #expect(s.respond("QRestoreRegisterState:\(id);thread:101;") == "OK")
        #expect(host.process.regs[0x101]?.pc == 0x1_0000_4008)
    }

    @Test func memoryAndBreakpoints() {
        let (s, host, c) = attachedServer()
        #expect(s.respond("m100004000,4") == "00010203")
        #expect(s.respond("m100004000,0") == "")
        #expect(s.respond("m200000000,4")?.hasPrefix("E") == true)
        // A read past the end of the mapping returns what is readable.
        #expect(s.respond("m10000403e,4") == "3e3f")
        #expect(s.respond("Z0,100004008,4") == "OK")
        #expect(host.process.memory[0x1_0000_400B] == 0xD4)
        #expect(s.respond("m100004008,4") == "08090a0b")
        #expect(s.respond("M100004008,2:ffee") == "OK")
        #expect(s.respond("m100004008,4") == "ffee0a0b")
        #expect(host.process.memory[0x1_0000_400B] == 0xD4)
        #expect(s.respond("z0,100004008,4") == "OK")
        #expect(s.respond("m100004008,4") == "ffee0a0b")
        // `x` replies with binary data (escaped by the framing).
        #expect(s.respond("x100004000,4") == nil)
        #expect(c.replies.last.map { Array($0.utf8) } == [0, 1, 2, 3])
        // `X`: binary write.
        s.handle(body: Array("X100004000,2:".utf8) + [0x7D, 0x23])
        #expect(host.process.readMemory(0x1_0000_4000, count: 2) == [0x7D, 0x23])
        #expect(s.respond("qMemoryRegionInfo:100004010") == "start:100004000;size:4000;permissions:rx;name:\(GDBRemoteHex.encode(text: "/app/Demo"));")
        #expect(s.respond("qMemoryRegionInfo:10") == "start:0;size:100004000;")
    }

    @Test func resumeActions() {
        let (s, host, c) = attachedServer()
        host.process.nextEvent = .stopped(thread: 0x102)
        host.process.stops[0x102] = GDBRemoteThreadStop(signal: 5, reason: .trace)
        // Step one thread, others stay stopped.
        #expect(s.respond("vCont;s:102") == nil)
        #expect(host.process.lastResume?.0 == [0x102: .step(signal: nil)])
        #expect(host.process.lastResume?.1 == .stop)
        // While running, packets other than the interrupt are refused.
        #expect(s.respond("qfThreadInfo")?.hasPrefix("E") == true)
        host.process.events.signal()
        let stop = c.waitForReplies(1).last ?? ""
        #expect(stop.hasPrefix("T05thread:102;"))
        #expect(stop.hasSuffix("reason:trace;"))
        for _ in 0..<1000 where s.respond("qC")?.hasPrefix("E") == true { usleep(1000) }
        #expect(s.respond("qC") == "QC102")
        // Step one, continue the others; a signal for one thread.
        host.process.nextEvent = .stopped(thread: 0x101)
        #expect(s.respond("vCont;s:101;c") == nil)
        #expect(host.process.lastResume?.0 == [0x101: .step(signal: nil)])
        #expect(host.process.lastResume?.1 == .continue(signal: nil))
        host.process.events.signal()
        _ = c.waitForReplies(2)
        for _ in 0..<1000 where s.respond("qC")?.hasPrefix("E") == true { usleep(1000) }
        #expect(s.respond("vCont;C0b:101;c") == nil)
        #expect(host.process.lastResume?.0 == [0x101: .continue(signal: 11)])
        host.process.nextEvent = .exited(status: 3)
        host.process.events.signal()
        #expect(c.waitForReplies(3).last == "W03")
        for _ in 0..<1000 where s.respond("qC") == "E10" { usleep(1000) }
        #expect(s.respond("?") == "W03")
        #expect(s.respond("qProcessInfo")?.hasPrefix("E") == true)
    }

    @Test func legacyContinueAndStep() {
        let (s, host, c) = attachedServer()
        #expect(s.respond("Hc102") == "OK")
        #expect(s.respond("s") == nil)
        #expect(host.process.lastResume?.0 == [0x102: .step(signal: nil)])
        #expect(host.process.lastResume?.1 == .stop)
        host.process.events.signal()
        _ = c.waitForReplies(1)
        for _ in 0..<1000 where s.respond("qC")?.hasPrefix("E") == true { usleep(1000) }
        #expect(s.respond("c") == nil)
        #expect(host.process.lastResume?.1 == .continue(signal: nil))
        host.process.events.signal()
        _ = c.waitForReplies(2)
    }

    @Test func attachDetachAndKill() {
        let host = FakeHost()
        host.attachAtConnect = false
        let c = FakeConnection()
        let s = GDBRemoteServer(host: host, connection: c)
        #expect(s.respond("qProcessInfo")?.hasPrefix("E") == true)
        #expect(s.respond("?") == "E02")
        #expect(s.respond("qC") == "QC0")
        #expect(s.respond("qfThreadInfo")?.hasPrefix("E") == true)
        #expect(s.respond("qfProcessInfo") == "pid:2a;name:\(GDBRemoteHex.encode(text: "Demo"));")
        #expect(s.respond("qsProcessInfo")?.hasPrefix("E") == true)
        #expect(s.respond("vAttach;99")?.hasPrefix("E") == true)
        host.process.stops[0x101] = GDBRemoteThreadStop(signal: 17, reason: .signal)
        let reply = s.respond("vAttachName;" + GDBRemoteHex.encode(text: "Demo")) ?? ""
        #expect(reply.hasPrefix("T11thread:101;"))
        #expect(!reply.contains("reason:"))
        #expect(s.respond("Z0,100004000,4") == "OK")
        #expect(s.respond("D") == "OK")
        #expect(host.process.detached)
        // Detaching removed the breakpoint.
        #expect(host.process.memory[0x1_0000_4003] == 3)
        #expect(s.respond("vAttach;2a")?.hasPrefix("T") == true)
        #expect(s.respond("k") == "X09")
        #expect(host.process.killed)
    }

    @Test func vContParsing() {
        #expect(GDBRemoteServer.action("c") == .continue(signal: nil))
        #expect(GDBRemoteServer.action("C0b") == .continue(signal: 11))
        #expect(GDBRemoteServer.action("S05") == .step(signal: 5))
        #expect(GDBRemoteServer.action("t") == .stop)
        #expect(GDBRemoteServer.action("x") == nil)
        #expect(GDBRemoteServer.splitThreadSuffix("p20;thread:1a;") == ("p20", 0x1A))
        #expect(GDBRemoteServer.splitThreadSuffix("qC") == ("qC", nil))
        #expect(GDBRemoteServer.addressAndLength("1000,20")! == (0x1000, 0x20))
    }
}

// MARK: Images, dyld's state, watchpoints (debug-stub.md §4.3, §6.2)

/// A minimal 64-bit Mach-O image: header, `__TEXT`, `LC_UUID`, `LC_BUILD_VERSION`.
private func machOImage(fileType: UInt32, vmaddr: UInt64, uuidByte: UInt8, platform: UInt32) -> [UInt8] {
    var b: [UInt8] = []
    func u32(_ v: UInt32) { for i in 0..<4 { b.append(UInt8(truncatingIfNeeded: v >> (8 * UInt32(i)))) } }
    func u64(_ v: UInt64) { for i in 0..<8 { b.append(UInt8(truncatingIfNeeded: v >> (8 * UInt64(i)))) } }
    u32(0xFEED_FACF); u32(0x0100_000C); u32(0x8000_0000); u32(fileType)
    u32(3); u32(72 + 24 + 24); u32(0x0020_0085); u32(0)
    // LC_SEGMENT_64 __TEXT
    u32(0x19); u32(72); b += Array("__TEXT".utf8) + [UInt8](repeating: 0, count: 10)
    u64(vmaddr); u64(0x4000); u64(0); u64(0x4000); u32(5); u32(5); u32(0); u32(0)
    // LC_UUID
    u32(0x1B); u32(24); b += [UInt8](repeating: uuidByte, count: 16)
    // LC_BUILD_VERSION: minos 27.0, sdk 27.1, no tools
    u32(0x32); u32(24); u32(platform); u32(0x001B_0000); u32(0x001B_0100); u32(0)
    return b
}

private func imageServer() -> (GDBRemoteServer, FakeProcess) {
    let (s, host, _) = attachedServer()
    let p = host.process
    for (i, byte) in machOImage(fileType: 2, vmaddr: 0x1_0000_0000, uuidByte: 0xAB, platform: 7).enumerated() {
        p.memory[0x1_0000_8000 + UInt64(i)] = byte
    }
    for (i, byte) in machOImage(fileType: 7, vmaddr: 0, uuidByte: 0xCD, platform: 7).enumerated() {
        p.memory[0x2_4000_0000 + UInt64(i)] = byte
    }
    p.images = [(0x1_0000_8000, "/apps/Demo.app/Demo"), (0x2_4000_0000, "/usr/lib/dyld_sim"), (0x9_0000_0000, "/nothing/there")]
    return (s, p)
}

@Suite struct GDBRemoteImageTests {
    @Test func readsAMachOHeaderFromMemory() throws {
        let bytes = machOImage(fileType: 2, vmaddr: 0x1_0000_0000, uuidByte: 0xAB, platform: 7)
        let info = try #require(GDBRemoteMachO.image(at: 0x1000, path: "/a") { a, n in
            let o = Int(a - 0x1000)
            return o < bytes.count ? Array(bytes[o..<min(bytes.count, o + n)]) : []
        })
        #expect(info.filetype == 2)
        #expect(info.cpusubtype == 0)   // the capability bits are dropped
        #expect(info.headerAndCommandsSize == 32 + 120)
        #expect(info.segments == [.init(name: "__TEXT", vmaddr: 0x1_0000_0000, vmsize: 0x4000, fileoff: 0, filesize: 0x4000, maxprot: 5)])
        #expect(info.uuid == [UInt8](repeating: 0xAB, count: 16))
        #expect(info.minimumOSName == "iossimulator")
        #expect(info.minimumOSVersion == "27.0")
        #expect(GDBRemoteMachO.versionString(0x000A_0F01) == "10.15.1")
        #expect(GDBRemoteMachO.image(at: 0x1000, path: "/a") { _, _ in [] } == nil)
    }

    @Test func parsesRequests() {
        #expect(GDBRemoteImageRequest.parse("") == nil)
        #expect(GDBRemoteImageRequest.parse("{\"fetch_all_solibs\":true,\"report_load_commands\":false}")
                == GDBRemoteImageRequest(selection: .all, detail: .addressOnly))
        #expect(GDBRemoteImageRequest.parse("{\"fetch_all_solibs\":true,\"information-level\":\"address-name-uuid\"}")
                == GDBRemoteImageRequest(selection: .all, detail: .addressNameUUID))
        #expect(GDBRemoteImageRequest.parse("{\"solib_addresses\":[4294967296,8382824135],\"information-level\":\"full\"}")
                == GDBRemoteImageRequest(selection: .addresses([0x1_0000_0000, 8_382_824_135]), detail: .full))
        #expect(GDBRemoteImageRequest.parse("{\"image_count\":2,\"image_list_address\":4096}")
                == GDBRemoteImageRequest(selection: .list(address: 4096, count: 2), detail: .full))
    }

    @Test func addressesOnlyThenDetailsInBatches() throws {
        let (s, _) = imageServer()
        // LLDB's first request on attach: every image, addresses only.
        #expect(s.respond("jGetLoadedDynamicLibrariesInfos:{\"fetch_all_solibs\":true,\"information-level\":\"address-only\",\"report_load_commands\":false}")
                == "{\"images\":[{\"load_address\":4295000064},{\"load_address\":9663676416},{\"load_address\":38654705664}]}")
        // Then the details of chosen images; an unreadable header is left out.
        let reply = try #require(s.respond("jGetLoadedDynamicLibrariesInfos:{\"solib_addresses\":[4295000064,38654705664],\"information-level\":\"full\"}"))
        let json = try #require(try JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any])
        let images = try #require(json["images"] as? [[String: Any]])
        #expect(images.count == 1)
        let image = images[0]
        #expect(image["pathname"] as? String == "/apps/Demo.app/Demo")
        #expect(image["uuid"] as? String == "ABABABAB-ABAB-ABAB-ABAB-ABABABABABAB")
        #expect(image["min_version_os_name"] as? String == "iossimulator")
        #expect(image["min_version_os_sdk"] as? String == "27.0")
        let mh = try #require(image["mach_header"] as? [String: Any])
        #expect(mh["magic"] as? Int == 0xFEED_FACF)
        #expect(mh["cputype"] as? Int == 0x0100_000C)
        #expect(mh["filetype"] as? Int == 2)
        #expect(mh["sizeof_mh_and_loadcmds"] as? Int == 152)
        let segments = try #require(image["segments"] as? [[String: Any]])
        #expect(segments.first?["name"] as? String == "__TEXT")
        #expect(segments.first?["vmaddr"] as? Int == 0x1_0000_0000)
        #expect(segments.first?["maxprot"] as? Int == 5)
    }

    @Test func everyImageInFullAndTheOlderListForm() throws {
        let (s, p) = imageServer()
        let all = try #require(s.respond("jGetLoadedDynamicLibrariesInfos:{\"fetch_all_solibs\":true}"))
        #expect(all.contains("\"filetype\":7"))
        #expect(all.contains("/usr/lib/dyld_sim"))
        // {"image_count","image_list_address"}: dyld_image_info entries in memory.
        var list: [UInt8] = []
        for v: UInt64 in [0x2_4000_0000, 0x3000, 0] { for i in 0..<8 { list.append(UInt8(truncatingIfNeeded: v >> (8 * UInt64(i)))) } }
        for (i, b) in (list + Array("/usr/lib/dyld_sim\0".utf8)).enumerated() where i < 24 { p.memory[0x2000 + UInt64(i)] = b }
        for (i, b) in Array("/usr/lib/dyld_sim\0".utf8).enumerated() { p.memory[0x3000 + UInt64(i)] = b }
        let old = try #require(s.respond("jGetLoadedDynamicLibrariesInfos:{\"image_count\":1,\"image_list_address\":8192}"))
        #expect(old.hasPrefix("{\"images\":[{\"load_address\":9663676416,\"pathname\":\"/usr/lib/dyld_sim\""))
    }

    @Test func dyldProcessState() {
        let (s, p) = imageServer()
        p.state = .notStarted
        #expect(s.respond("jGetDyldProcessState") == "{\"process_state_value\":0,\"process_state string\":\"dyld_process_state_not_started\"}")
        p.state = .libSystemInitialized
        #expect(s.respond("jGetDyldProcessState") == "{\"process_state_value\":48,\"process_state string\":\"dyld_process_state_libSystem_initialized\"}")
        #expect(GDBRemoteDyldState.programRunning.rawValue == 0x50)
    }

    @Test func watchpointsAndTheirStops() {
        let (s, host, _) = attachedServer()
        let p = host.process
        p.slots = 2
        #expect(s.respond("qWatchpointSupportInfo:") == "num:2;")
        #expect(s.respond("Z2,16fdff8a0,8") == "OK")
        #expect(s.respond("Z4,1000,4") == "OK")
        #expect(s.respond("Z3,2000,4")?.hasPrefix("E") == true)   // no third register
        #expect(p.watches.map(\.2) == [.write, .access])
        #expect(s.respond("z4,1000,4") == "OK")
        #expect(p.watches.count == 1)
        p.stops[0x101] = GDBRemoteThreadStop(signal: 5, reason: .watchpoint(address: 0x16_fdff_f8a0, index: 0, hit: 0x16_fdff_f8a0))
        let reply = s.stopReply(p, thread: 0x101)
        #expect(reply.hasPrefix("T05thread:101;"))
        #expect(reply.hasSuffix("reason:watchpoint;description:\(GDBRemoteHex.encode(text: "98750691488 0 98750691488"));"))
        #expect(s.threadsInfoJSON(p).contains("\"reason\":\"watchpoint\",\"description\":\"98750691488 0 98750691488\""))
    }
}
