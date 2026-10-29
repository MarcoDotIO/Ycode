import Foundation
import Testing
import YcodeDarwinABI
@testable import YcodeDarwinKernel
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

// Host passthrough networking (`specs/simulator/networking-ycode.md`):
// the Darwin ↔ host translations, the IP socket calls on real host
// sockets (loopback only), readiness through poll and kevent, the interface
// model, the DNS service's codec and its server over the AF_UNIX path.

private let addrVA = DEnv.scratch + 0x600
private let lenVA = DEnv.scratch + 0x6F0
private let optVA = DEnv.scratch + 0x700
private let bufVA = DEnv.scratch + 0x4000

private func sockaddrIn(_ a: [UInt8], port: UInt16) -> [UInt8] {
    InetAddress(family: InetABI.afInet, port: port, address: a).darwinBytes
}

private func sockaddrIn6(_ a: [UInt8], port: UInt16) -> [UInt8] {
    InetAddress(family: InetABI.afInet6, port: port, address: a).darwinBytes
}

private let loopback6: [UInt8] = [UInt8](repeating: 0, count: 15) + [1]

extension DEnv {
    func inetSocket(_ domain: UInt64 = 2, _ type: UInt64 = 1, _ proto: UInt64 = 0) -> Int32 {
        let r = call(97, [domain, type, proto])
        precondition(!r.carry, "socket failed: \(r.x0)")
        return r.fd
    }

    @discardableResult
    func bindInet(_ fd: Int32, _ sa: [UInt8]) -> Result {
        put(sa, at: addrVA)
        return call(104, [UInt64(fd), addrVA, UInt64(sa.count)])
    }

    @discardableResult
    func connectInet(_ fd: Int32, _ sa: [UInt8]) -> Result {
        put(sa, at: addrVA)
        return call(98, [UInt64(fd), addrVA, UInt64(sa.count)])
    }

    /// getsockname / getpeername → the Darwin sockaddr bytes.
    func name(_ fd: Int32, peer: Bool = false) -> (Result, [UInt8]) {
        put([128, 0, 0, 0], at: lenVA)
        let r = call(peer ? 31 : 32, [UInt64(fd), addrVA, lenVA])
        return (r, r.carry ? [] : get(addrVA, Int(u32(lenVA))))
    }

    func port(_ fd: Int32) -> UInt16 {
        let b = name(fd).1
        return UInt16(b[2]) << 8 | UInt16(b[3])
    }

    func setNonBlocking(_ fd: Int32) {
        precondition(!call(92, [UInt64(fd), 4, 4]).carry)  // F_SETFL O_NONBLOCK
    }

    /// poll(1 fd, events, timeout ms) → (count, revents).
    func poll(_ fd: Int32, events: Int16, timeout: Int32) -> (Int, Int16) {
        var p: [UInt8] = []
        p.appendLE(fd)
        p.appendLE(events)
        p.appendLE(Int16(0))
        put(p, at: bufVA + 0x3000)
        let r = call(230, [bufVA + 0x3000, 1, UInt64(UInt32(bitPattern: timeout))])
        return (Int(r.value ?? 0), Int16(bitPattern: UInt16(truncatingIfNeeded: get(bufVA + 0x3006, 2).readLE(UInt16.self, at: 0))))
    }

    func sendBytes(_ fd: Int32, _ bytes: [UInt8]) -> Result {
        put(bytes, at: bufVA)
        return call(133, [UInt64(fd), bufVA, UInt64(bytes.count), 0, 0, 0])
    }

    func receiveBytes(_ fd: Int32, max: Int = 4096, flags: UInt64 = 0) -> (Result, [UInt8]) {
        let r = call(29, [UInt64(fd), bufVA + 0x8000, UInt64(max), flags, 0, 0])
        return (r, r.carry ? [] : get(bufVA + 0x8000, Int(r.x0)))
    }

    func getInetOption(_ fd: Int32, _ level: UInt32, _ name: UInt32) -> (Int32?, [UInt8]) {
        put([UInt8](repeating: 0xEE, count: 128), at: optVA)
        put([128, 0, 0, 0], at: lenVA)
        let r = call(118, [UInt64(fd), UInt64(level), UInt64(name), optVA, lenVA])
        if let e = r.errno { return (e, []) }
        return (nil, get(optVA, Int(u32(lenVA))))
    }

    @discardableResult
    func setInetOption(_ fd: Int32, _ level: UInt32, _ name: UInt32, _ value: [UInt8]) -> Result {
        put(value, at: optVA)
        return call(105, [UInt64(fd), UInt64(level), UInt64(name), optVA, UInt64(value.count)])
    }

    func close(_ fd: Int32) { call(6, [UInt64(fd)]) }
}

private func int32Bytes(_ v: Int32) -> [UInt8] {
    var b: [UInt8] = []
    b.appendLE(v)
    return b
}

@Suite(.serialized) struct NetworkingTests {
    // MARK: Translations

    @Test func addressConversion() throws {
        let a = InetAddress.ipv4(127, 0, 0, 1, port: 8080)
        let d = a.darwinBytes
        #expect(d.count == 16 && d[0] == 16 && d[1] == 2 && d[2] == 0x1F && d[3] == 0x90 && Array(d[4..<8]) == [127, 0, 0, 1])
        #expect(try InetAddress.fromDarwin(d, domain: InetABI.afInet) == a)
        let back = InetAddress.fromHost(a.hostBytes(hostScope: 0), guestScope: { $0 })
        #expect(back == a)
        let v6 = InetAddress(family: InetABI.afInet6, port: 443, address: loopback6, flowInfo: 7, scope: 2)
        let d6 = v6.darwinBytes
        #expect(d6.count == 28 && d6[0] == 28 && d6[1] == 30 && d6.readLE(UInt32.self, at: 24) == 2)
        #expect(try InetAddress.fromDarwin(d6, domain: InetABI.afInet6) == v6)
        // The host scope is mapped both ways.
        let h6 = v6.hostBytes(hostScope: 9)
        #expect(h6.readLE(UInt32.self, at: 24) == 9)
        #expect(InetAddress.fromHost(h6, guestScope: { $0 == 9 ? 2 : 0 })?.scope == 2)
        // Errors: short, wrong family for the domain, unknown family.
        #expect(throws: DarwinErrnoError.self) { try InetAddress.fromDarwin(Array(d.prefix(8)), domain: InetABI.afInet) }
        do {
            _ = try InetAddress.fromDarwin(d, domain: InetABI.afInet6)
            Issue.record("AF_INET address on an AF_INET6 socket accepted")
        } catch let e as DarwinErrnoError { #expect(e.errno == DarwinErrnoCode.EAFNOSUPPORT) }
    }

    @Test func errnoAndFlagTranslation() {
        #if os(Linux)
        #expect(SocketErrno.fromHost(11) == 35)    // EAGAIN
        #expect(SocketErrno.fromHost(115) == 36)   // EINPROGRESS
        #expect(SocketErrno.fromHost(111) == 61)   // ECONNREFUSED
        #expect(SocketErrno.fromHost(104) == 54)   // ECONNRESET
        #expect(SocketErrno.fromHost(98) == 48)    // EADDRINUSE
        #expect(SocketErrno.fromHost(95) == 102)   // EOPNOTSUPP
        #expect(SocketErrno.fromHost(32) == 32)    // EPIPE
        #expect(SocketFlags.hostCallFlags(InetABI.msgPeek) == 0x2 | 0x40 | 0x4000)
        #expect(SocketFlags.darwinReceivedFlags(0x20 | 0x8) == InetABI.msgTrunc | InetABI.msgCtrunc)
        #else
        #expect(SocketErrno.fromHost(35) == 35)
        #endif
    }

    @Test func optionRoutesAndValues() throws {
        #if os(Linux)
        #expect(SocketOptions.route(level: 0xFFFF, name: InetABI.soReuseAddr) == .host(level: 1, name: 2, kind: .int))
        #expect(SocketOptions.route(level: 0xFFFF, name: InetABI.soReusePort) == .host(level: 1, name: 15, kind: .int))
        #expect(SocketOptions.route(level: 6, name: InetABI.tcpKeepAlive) == .host(level: 6, name: 4, kind: .int))
        #expect(SocketOptions.route(level: 41, name: InetABI.ipv6V6Only) == .host(level: 41, name: 26, kind: .int))
        #expect(SocketOptions.route(level: 41, name: InetABI.ipv6RecvPktInfo) == .host(level: 41, name: 49, kind: .int))
        #expect(SocketOptions.route(level: 0, name: InetABI.ipMulticastTTL) == .host(level: 0, name: 33, kind: .uchar))
        #expect(SocketOptions.route(level: 0xFFFF, name: 0x1116) == .local)  // SO_NET_SERVICE_TYPE
        #expect(SocketOptions.route(level: 6, name: InetABI.tcpNoPush) == .local)
        #endif
        // SO_LINGER is in ticks (hz 100), SO_LINGER_SEC in seconds.
        var linger: [UInt8] = []
        linger.appendLE(Int32(1)); linger.appendLE(Int32(250))
        let h = try SocketOptions.hostValue(linger, kind: .linger(ticks: true), hostIndex: { $0 })
        #expect(h.readLE(Int32.self, at: 4) == 3)
        #expect(SocketOptions.guestValue(h, kind: .linger(ticks: true), guestIndex: { $0 }).readLE(Int32.self, at: 4) == 300)
        // u_char options accept one byte and answer one byte.
        #expect(try SocketOptions.hostValue([7], kind: .uchar, hostIndex: { $0 }) == [7, 0, 0, 0])
        #expect(SocketOptions.guestValue([7, 0, 0, 0], kind: .uchar, guestIndex: { $0 }) == [7])
        // Interface indexes inside ipv6_mreq are mapped.
        var mreq = [UInt8](repeating: 0xFF, count: 16)
        mreq.appendLE(UInt32(2))
        #expect(try SocketOptions.hostValue(mreq, kind: .ipv6Mreq, hostIndex: { $0 == 2 ? 5 : 0 }).readLE(UInt32.self, at: 16) == 5)
        #expect(throws: DarwinErrnoError.self) { try SocketOptions.hostValue([1, 2], kind: .int, hostIndex: { $0 }) }
    }

    @Test func controlMessageLayouts() throws {
        let ms = [ControlMessage(level: 0, type: InetABI.ipRecvDstAddr, data: [127, 0, 0, 1]),
                  ControlMessage(level: 0, type: InetABI.ipRecvTTL, data: [64])]
        let d = ControlMessages.encodeDarwin(ms, room: 64)
        // 12-byte headers, 4-byte alignment: 16 + 16.
        #expect(!d.truncated && d.bytes.count == 32 && d.bytes.readLE(UInt32.self, at: 0) == 16 && d.bytes.readLE(UInt32.self, at: 16) == 13)
        #expect(try ControlMessages.parseDarwin(d.bytes) == ms)
        #expect(ControlMessages.encodeDarwin(ms, room: 20).truncated)
        let h = ControlMessages.encodeHost(ms)
        #expect(ControlMessages.parseHost(h) == ms)
        #if os(Linux)
        // Linux IP_PKTINFO (8) → Darwin IP_RECVDSTADDR and IP_PKTINFO (26), index mapped.
        var info: [UInt8] = []
        info.appendLE(UInt32(9))
        info += [127, 0, 0, 1, 127, 0, 0, 2]
        let out = ControlMessages.darwinReceived([ControlMessage(level: 0, type: 8, data: info)],
                                                 wants: .init(dstAddr: true, pktInfo: true, recvIF: false, ttl: false, tos: false),
                                                 guestIndex: { $0 == 9 ? 1 : 0 }, interfaceName: { _ in "lo0" })
        #expect(out.count == 2)
        #expect(out[0] == ControlMessage(level: 0, type: InetABI.ipRecvDstAddr, data: [127, 0, 0, 2]))
        #expect(out[1].type == InetABI.ipPktInfo && out[1].data.readLE(UInt32.self, at: 0) == 1)
        // Linux IP_TTL (int) → Darwin IP_RECVTTL (u_char).
        let ttl = ControlMessages.darwinReceived([ControlMessage(level: 0, type: 2, data: [64, 0, 0, 0])], wants: .init(),
                                                 guestIndex: { $0 }, interfaceName: { _ in nil })
        #expect(ttl == [ControlMessage(level: 0, type: InetABI.ipRecvTTL, data: [64])])
        #endif
        #expect(throws: DarwinErrnoError.self) {
            try ControlMessages.hostSent([ControlMessage(level: 0xFFFF, type: 1, data: [0, 0, 0, 0])], hostIndex: { $0 })
        }
    }

    // MARK: DNS codecs

    @Test func dnsMessageCodec() throws {
        let q = try #require(DNSMessage.query(id: 0x1234, name: "example.com", type: 28, rrclass: 1))
        #expect(q.readBE16(at: 0) == 0x1234 && q.readBE16(at: 2) == 0x0100 && q.readBE16(at: 4) == 1 && q.readBE16(at: 10) == 1)
        #expect(Array(q[12..<25]) == [7] + Array("example".utf8) + [3] + Array("com".utf8) + [0])
        #expect(DNSMessage.encodeName(String(repeating: "a", count: 64) + ".com") == nil)
        // A response: the question, a CNAME (compressed), then an A record for the CNAME target.
        var m: [UInt8] = []
        m.appendBE16(0x1234); m.appendBE16(0x8180); m.appendBE16(1); m.appendBE16(2); m.appendBE16(0); m.appendBE16(0)
        m += [3] + Array("www".utf8) + [7] + Array("example".utf8) + [3] + Array("com".utf8) + [0]
        m.appendBE16(1); m.appendBE16(1)
        m += [0xC0, 12]                                           // www.example.com
        m.appendBE16(5); m.appendBE16(1); m.appendBE32(300); m.appendBE16(2)
        m += [0xC0, 16]                                           // example.com (compressed rdata)
        m += [0xC0, 16]
        m.appendBE16(1); m.appendBE16(1); m.appendBE32(60); m.appendBE16(4)
        m += [93, 184, 216, 34]
        guard case let .records(rs)? = DNSMessage.outcome(m, id: 0x1234, type: 1) else {
            Issue.record("no records")
            return
        }
        #expect(rs.count == 2)
        #expect(rs[0].type == 5 && rs[0].name == "www.example.com." && rs[0].rdata == [7] + Array("example".utf8) + [3] + Array("com".utf8) + [0])
        #expect(rs[1] == HostResolver.Record(name: "example.com.", type: 1, rrclass: 1, ttl: 60, rdata: [93, 184, 216, 34]))
        #expect(DNSMessage.outcome(m, id: 0x9999, type: 1) == nil)
        var nx = Array(m.prefix(12))
        nx[3] = 0x83
        nx.putBE16(0, at: 6)
        #expect(DNSMessage.outcome(nx, id: 0x1234, type: 1) == .noSuchName)
    }

    @Test func dnsServiceIPCCodec() {
        let ctx: [UInt8] = [1, 2, 3, 4, 5, 6, 7, 8]
        let h = DNSServiceIPC.Header(datalen: 20, ipcFlags: 2, op: 15, context: ctx, regIndex: 3)
        let b = h.bytes
        #expect(b.count == 28 && b.readBE32(at: 0) == 1 && b.readBE32(at: 4) == 20 && b.readBE32(at: 12) == 15 && Array(b[16..<24]) == ctx)
        #expect(DNSServiceIPC.Header(b[...]) == h)
        var data: [UInt8] = []
        data.appendBE32(0x10); data.appendBE32(2); data.appendBE32(1)
        data += Array("host.test".utf8) + [0]
        var r = DNSServiceIPC.Reader(data)
        #expect(r.u32() == 0x10 && r.u32() == 2 && r.u32() == 1 && r.string() == "host.test" && !r.failed)
        _ = r.u32()
        #expect(r.failed)
        let reply = DNSServiceIPC.reply(op: 72, context: ctx, flags: 3, interface: 2, error: -65554,
                                        body: DNSServiceIPC.answer(name: "h", type: 28, rdata: [], ttl: 0))
        #expect(reply.readBE32(at: 12) == 72 && Array(reply[16..<24]) == ctx)
        #expect(reply.readBE32(at: 28) == 3 && reply.readBE32(at: 32) == 2 && Int32(bitPattern: reply.readBE32(at: 36)) == -65554)
        #expect(Array(reply[40...]) == [0x68, 0, 0, 28, 0, 1, 0, 0, 0, 0, 0, 0])
    }

    // MARK: Interfaces

    private static let model = [
        GuestInterface(name: "lo0", index: 1, hostIndex: 1, hostName: "lo", flags: 0x8049, mtu: 16384, type: 0x18, linkAddress: [],
                       ipv4: [.init(address: [127, 0, 0, 1], netmask: [255, 0, 0, 0], broadcast: nil)],
                       ipv6: [.init(address: loopback6, prefixLength: 128)]),
        GuestInterface(name: "en0", index: 2, hostIndex: 7, hostName: "eth0", flags: 0x8863, mtu: 1500, type: 6,
                       linkAddress: [2, 1, 2, 3, 4, 5],
                       ipv4: [.init(address: [10, 0, 0, 5], netmask: [255, 255, 255, 0], broadcast: [10, 0, 0, 255])],
                       ipv6: [.init(address: [0xFE, 0x80] + [UInt8](repeating: 0, count: 13) + [5], prefixLength: 64)],
                       gateway4: [10, 0, 0, 1]),
    ]

    @Test func interfaceModelSysctlsAndIoctls() throws {
        NetworkInterfaces.override = Self.model
        defer { NetworkInterfaces.override = nil }
        #expect(NetworkInterfaces.hostIndex(2) == 7 && NetworkInterfaces.guestIndex(7) == 2 && NetworkInterfaces.guestIndex(99) == 0)
        // NET_RT_IFLIST2: RTM_IFINFO2 (160-byte header + sockaddr_dl), then RTM_NEWADDRs.
        let list = try #require(NetworkInterfaces.routingSysctl([4, 17, 0, 0, 6, 0]))
        var off = 0
        var messages: [(type: UInt8, index: UInt16, length: Int)] = []
        while off < list.count {
            let len = Int(list.readLE(UInt16.self, at: off))
            #expect(len > 0 && list[off + 2] == 5)
            messages.append((list[off + 3], list.readLE(UInt16.self, at: off + 12), len))
            if list[off + 3] == 0x12 {
                #expect(list[off + 160 + 1] == 18)  // sockaddr_dl right after the header
                let nlen = Int(list[off + 160 + 5])
                let name = String(decoding: list[(off + 168)..<(off + 168 + nlen)], as: UTF8.self)
                #expect(name == (messages.filter { $0.type == 0x12 }.count == 1 ? "lo0" : "en0"))
            }
            off += len
        }
        #expect(off == list.count)
        #expect(messages.map(\.type) == [0x12, 0x0C, 0x0C, 0x12, 0x0C, 0x0C])
        // Filtered by index and family.
        let en4 = try #require(NetworkInterfaces.routingSysctl([4, 17, 0, 2, 3, 2]))
        #expect(en4[3] == 0x0E && Int(en4.readLE(UInt16.self, at: 0)) == 112 + 20 && en4.count == 132 + 20 + 16 * 3)
        // NET_RT_DUMP: the default route through en0's gateway.
        let dump = try #require(NetworkInterfaces.routingSysctl([4, 17, 0, 2, 1, 0]))
        var found = false
        off = 0
        while off < dump.count {
            let len = Int(dump.readLE(UInt16.self, at: off))
            let flags = dump.readLE(Int32.self, at: off + 8)
            if flags & 0x2 != 0 {
                #expect(dump.readLE(UInt16.self, at: off + 4) == 2)
                #expect(Array(dump[(off + 92 + 4)..<(off + 92 + 8)]) == [0, 0, 0, 0])        // RTA_DST
                #expect(Array(dump[(off + 92 + 16 + 4)..<(off + 92 + 16 + 8)]) == [10, 0, 0, 1])  // RTA_GATEWAY
                found = true
            }
            off += len
        }
        #expect(found)
        #expect(NetworkInterfaces.routingSysctl([4, 17, 0, 0, 99]) == nil)
        // SIOCGIFFLAGS / SIOCGIFMTU / SIOCGIFADDR; an unknown name is ENXIO.
        var req = Array("en0".utf8) + [UInt8](repeating: 0, count: 29)
        guard case let .reply(flags) = NetworkInterfaces.ioctl(0xC020_6911, argument: req) else { Issue.record("flags"); return }
        #expect(flags.readLE(Int16.self, at: 16) == Int16(bitPattern: 0x8863))
        guard case let .reply(mtu) = NetworkInterfaces.ioctl(0xC020_6933, argument: req) else { Issue.record("mtu"); return }
        #expect(mtu.readLE(Int32.self, at: 16) == 1500)
        guard case let .reply(addr) = NetworkInterfaces.ioctl(0xC020_6921, argument: req) else { Issue.record("addr"); return }
        #expect(Array(addr[20..<24]) == [10, 0, 0, 5] && addr[17] == 2)
        req = Array("eth9".utf8) + [UInt8](repeating: 0, count: 28)
        #expect(NetworkInterfaces.ioctl(0xC020_6911, argument: req) == .failure(DarwinErrnoCode.ENXIO))
        guard case let .configuration(conf) = NetworkInterfaces.ioctl(NetworkInterfaces.siocGIfConf, argument: [UInt8](repeating: 0, count: 12)) else {
            Issue.record("ifconf")
            return
        }
        // lo0: link (16 + 20), 127.0.0.1 (32), ::1 (16 + 28); en0: link, 10.0.0.5, fe80::5.
        #expect(conf.map(\.count) == [36, 32, 44, 36, 32, 44])
    }

    @Test func routingSysctlThroughTheKernel() throws {
        NetworkInterfaces.override = Self.model
        defer { NetworkInterfaces.override = nil }
        let e = try DEnv()
        var mib: [UInt8] = []
        for v: Int32 in [4, 17, 0, 0, 6, 0] { mib.appendLE(v) }
        e.put(mib, at: bufVA)
        e.put([UInt8](repeating: 0, count: 8), at: lenVA)
        let size = e.call(202, [bufVA, 6, 0, lenVA, 0, 0])
        #expect(!size.carry)
        let n = e.get(lenVA, 8).readLE(UInt64.self, at: 0)
        #expect(n == UInt64(NetworkInterfaces.interfaceList(family: 0, index: 0, version2: true).count))
        var room: [UInt8] = []
        room.appendLE(n)
        e.put(room, at: lenVA)
        #expect(!e.call(202, [bufVA, 6, bufVA + 0x100, lenVA, 0, 0]).carry)
        #expect(e.get(bufVA + 0x100 + 3, 1) == [0x12])
    }

    @Test func routeSocketAnswersRTMGet() throws {
        NetworkInterfaces.override = Self.model
        defer { NetworkInterfaces.override = nil }
        let e = try DEnv()
        let r = e.call(97, [17, 3, 17])
        #expect(!r.carry)
        let fd = r.fd
        #expect(e.call(97, [17, 2, 0]).errno == DarwinErrnoCode.EPROTOTYPE)
        // RTM_GET for 93.184.216.34 with RTA_DST | RTA_IFP.
        func get(_ dst: [UInt8], seq: Int32) -> (DEnv.Result, [UInt8]) {
            var m = [UInt8](repeating: 0, count: 92)
            m[2] = 5; m[3] = 4
            m.putLE(Int32(0x1 | 0x10), at: 12)
            m.putLE(seq, at: 20)
            m += dst
            m += NetworkInterfaces.sockaddrDL(index: 0, name: "", type: 0, address: [])
            m.putLE(UInt16(m.count), at: 0)
            e.put(m, at: bufVA)
            let w = e.call(4, [UInt64(fd), bufVA, UInt64(m.count)])
            let rd = e.call(3, [UInt64(fd), bufVA + 0x1000, 512])
            return (w, rd.carry ? [] : e.get(bufVA + 0x1000, Int(rd.x0)))
        }
        let (w, reply) = get(sockaddrIn([93, 184, 216, 34], port: 0), seq: 7)
        #expect(w.value != nil)
        #expect(reply.count == Int(reply.readLE(UInt16.self, at: 0)) && reply[3] == 4)
        #expect(reply.readLE(UInt32.self, at: 40) == 1500)                    // rmx_mtu
        #expect(reply.readLE(UInt16.self, at: 4) == 2)                       // en0
        #expect(reply.readLE(Int32.self, at: 8) & 0x2 != 0)                   // RTF_GATEWAY
        #expect(reply.readLE(Int32.self, at: 20) == 7 && reply.readLE(Int32.self, at: 24) == 0)
        #expect(reply.readLE(Int32.self, at: 12) == 0x1 | 0x2 | 0x4 | 0x10 | 0x20)
        #expect(Array(reply[(92 + 16 + 4)..<(92 + 16 + 8)]) == [10, 0, 0, 1])  // the gateway
        // RTM_GET_SILENT for the default route (networking.md §3.6): an RTM_GET
        // answer with the empty netmask; 92 + 16 + 16 + 4 + 20 + 16 bytes.
        var silent = [UInt8](repeating: 0, count: 92)
        silent[2] = 5; silent[3] = 0x11
        silent.putLE(Int32(0x807), at: 8)
        silent.putLE(Int32(0x1 | 0x10), at: 12)
        silent += sockaddrIn([0, 0, 0, 0], port: 0) + NetworkInterfaces.sockaddrDL(index: 0, name: "", type: 0, address: [])
        silent.putLE(UInt16(silent.count), at: 0)
        #expect(silent.count == 128)
        e.put(silent, at: bufVA)
        #expect(e.call(4, [UInt64(fd), bufVA, 128]).value == 128)
        let sr = e.call(3, [UInt64(fd), bufVA + 0x1000, 512])
        #expect(sr.value == 164 && e.get(bufVA + 0x1003, 1) == [4])
        #expect(e.get(bufVA + 0x1008, 4).readLE(UInt32.self, at: 0) == 0x4001_0843)
        // Loopback goes through lo0; an IPv6 destination with no route: ESRCH.
        #expect(get(sockaddrIn([127, 0, 0, 1], port: 0), seq: 8).1.readLE(UInt16.self, at: 4) == 1)
        let (w6, r6) = get(sockaddrIn6([0x20, 1, 0xd, 0xb8] + [UInt8](repeating: 0, count: 12), port: 0), seq: 9)
        #expect(w6.errno == 3 && r6.readLE(Int32.self, at: 24) == 3)
        e.close(fd)
    }

    @Test func netsrcKernelControl() throws {
        let e = try DEnv()
        let r = e.call(97, [32, 2, 2])
        #expect(!r.carry)
        let fd = r.fd
        // CTLIOCGINFO: netsrc is found, another name is ENOENT.
        var info = [UInt8](repeating: 0, count: 100)
        info.replaceSubrange(4..<(4 + 16), with: Array("com.apple.netsrc".utf8))
        e.put(info, at: bufVA)
        #expect(e.call(54, [UInt64(fd), 0xC064_4E03, bufVA]).value == 0)
        let id = e.u32(bufVA)
        var other = [UInt8](repeating: 0, count: 100)
        other.replaceSubrange(4..<(4 + 9), with: Array("com.x.y.z".utf8))
        e.put(other, at: bufVA + 0x200)
        #expect(e.call(54, [UInt64(fd), 0xC064_4E03, bufVA + 0x200]).errno == DarwinErrnoCode.ENOENT)
        // connect with sockaddr_ctl, then a version-2 request for 127.0.0.1:80.
        var sc: [UInt8] = [32, 32]
        sc.appendLE(UInt16(2)); sc.appendLE(id); sc.appendLE(UInt32(0))
        sc += [UInt8](repeating: 0, count: 20)
        #expect(e.connectInet(fd, sc).value == 0)
        var req: [UInt8] = []
        req.appendLE(UInt32(2)); req.appendLE(UInt32(0))
        req += sockaddrIn([127, 0, 0, 1], port: 80) + [UInt8](repeating: 0, count: 12)
        #expect(req.count == 36)
        #expect(e.sendBytes(fd, req).value == 36)
        let (rr, reply) = e.receiveBytes(fd)
        #expect(rr.value == 56)
        #expect(reply[1] == 2 && Array(reply[4..<8]) == [127, 0, 0, 1])          // source 127.0.0.1
        #expect(reply.readLE(UInt32.self, at: 40) == 0x20)                       // ROUTEABLE
        #expect(reply.readLE(UInt16.self, at: 48) == 4 && reply.readLE(UInt16.self, at: 50) == 35)  // dst label/precedence
        e.close(fd)
    }

    // MARK: Sockets on the host

    @Test func tcpLoopbackLifecycle() throws {
        let e = try DEnv()
        let l = e.inetSocket()
        #expect(e.bindInet(l, sockaddrIn([127, 0, 0, 1], port: 0)).value == 0)
        #expect(e.call(106, [UInt64(l), 8]).value == 0)
        let port = e.port(l)
        #expect(port != 0)
        let (_, bound) = e.name(l)
        #expect(bound.count == 16 && bound[0] == 16 && bound[1] == 2 && Array(bound[4..<8]) == [127, 0, 0, 1])
        // Listening: readable once a connection waits.
        #expect(e.poll(l, events: 1, timeout: 0).0 == 0)

        let c = e.inetSocket()
        #expect(e.setInetOption(c, 6, UInt32(InetABI.tcpNoDelay), int32Bytes(1)).value == 0)
        #expect(e.getInetOption(c, 6, UInt32(InetABI.tcpNoDelay)).1.readLE(Int32.self, at: 0) != 0)
        #expect(e.getInetOption(c, 0xFFFF, UInt32(InetABI.soType)).1 == int32Bytes(1))
        #expect(e.connectInet(c, sockaddrIn([127, 0, 0, 1], port: port)).value == 0)
        #expect(e.connectInet(c, sockaddrIn([127, 0, 0, 1], port: port)).errno == DarwinErrnoCode.EISCONN)
        let ready = e.poll(l, events: 1, timeout: 2000)
        #expect(ready.0 == 1 && ready.1 & 1 != 0)
        put0(e)
        let a = e.call(30, [UInt64(l), addrVA, lenVA])
        #expect(!a.carry)
        let s = a.fd
        #expect(e.u32(lenVA) == 16)
        let (_, peer) = e.name(c, peer: true)
        #expect(UInt16(peer[2]) << 8 | UInt16(peer[3]) == port)

        #expect(e.sendBytes(c, Array("ping".utf8)).value == 4)
        #expect(e.poll(s, events: 1, timeout: 2000).0 == 1)
        // FIONREAD
        let fionread = e.call(54, [UInt64(s), 0x4004_667F, bufVA + 0x2000])
        #expect(fionread.value == 0 && e.u32(bufVA + 0x2000) == 4)
        #expect(e.receiveBytes(s).1 == Array("ping".utf8))
        // Non-blocking read with nothing queued: EAGAIN.
        e.setNonBlocking(s)
        #expect(e.receiveBytes(s).0.errno == DarwinErrnoCode.EAGAIN)
        // Shutdown for writing: the peer reads EOF and polls POLLHUP.
        #expect(e.call(134, [UInt64(c), 1]).value == 0)
        let hup = e.poll(s, events: 1, timeout: 2000)
        #expect(hup.0 == 1 && hup.1 & 0x10 != 0)
        #expect(e.receiveBytes(s).0.value == 0)
        // A write after the peer closed: EPIPE (SIGPIPE suppressed with SO_NOSIGPIPE).
        #expect(e.setInetOption(s, 0xFFFF, UInt32(InetABI.soNoSigPipe), int32Bytes(1)).value == 0)
        e.close(c)
        var failed = false
        for _ in 0..<20 {
            let w = e.sendBytes(s, [1])
            if let err = w.errno {
                #expect(err == DarwinErrnoCode.EPIPE || err == DarwinErrnoCode.ECONNRESET)
                failed = true
                break
            }
            usleep(20_000)
        }
        #expect(failed)
        e.close(s)
        e.close(l)
    }

    private func put0(_ e: DEnv) { e.put([128, 0, 0, 0], at: lenVA) }

    @Test func nonBlockingConnectAndKEvent() throws {
        let e = try DEnv()
        let l = e.inetSocket(30)
        #expect(e.bindInet(l, sockaddrIn6(loopback6, port: 0)).value == 0)
        #expect(e.call(106, [UInt64(l), 8]).value == 0)
        let port = e.port(l)
        let c = e.inetSocket(30)
        e.setNonBlocking(c)
        let r = e.connectInet(c, sockaddrIn6(loopback6, port: port))
        #expect(r.value == 0 || r.errno == SocketErrno.EINPROGRESS)
        // kqueue + EVFILT_WRITE: the connect completes.
        let kq = e.call(362).fd
        var change = [UInt8](repeating: 0, count: 32)
        change.putLE(UInt64(c), at: 0)
        change.putLE(Int16(-2), at: 8)                 // EVFILT_WRITE
        change.putLE(UInt16(0x1 | 0x10), at: 10)       // EV_ADD | EV_ONESHOT
        e.put(change, at: bufVA + 0x1000)
        var ts: [UInt8] = []
        ts.appendLE(Int64(5)); ts.appendLE(Int64(0))
        e.put(ts, at: bufVA + 0x1100)
        let n = e.call(363, [UInt64(kq), bufVA + 0x1000, 1, bufVA + 0x1200, 1, bufVA + 0x1100])
        #expect(n.value == 1 && e.get(bufVA + 0x1208, 2).readLE(Int16.self, at: 0) == -2)
        #expect(e.getInetOption(c, 0xFFFF, UInt32(InetABI.soError)).1 == int32Bytes(0))
        put0(e)
        let s = e.call(30, [UInt64(l), addrVA, lenVA]).fd
        #expect(e.u32(lenVA) == 28 && e.get(addrVA + 1, 1) == [30])
        // EVFILT_READ fires when a host write lands, with the byte count.
        change.putLE(Int16(-1), at: 8)                 // EVFILT_READ
        change.putLE(UInt16(0x1), at: 10)              // EV_ADD
        e.put(change, at: bufVA + 0x1000)
        let writer = HostThread { () -> Bool in
            usleep(100_000)
            return true
        }
        _ = writer.wait()
        #expect(e.sendBytes(s, Array("hello".utf8)).value == 5)
        let m = e.call(363, [UInt64(kq), bufVA + 0x1000, 1, bufVA + 0x1200, 1, bufVA + 0x1100])
        #expect(m.value == 1 && e.get(bufVA + 0x1208, 2).readLE(Int16.self, at: 0) == -1
                && e.get(bufVA + 0x1210, 8).readLE(Int64.self, at: 0) == 5)
        e.close(s)
        e.close(c)
        e.close(l)
        e.close(kq)
    }

    @Test func evfiltSockReportsConnectedOnceThenReadClosed() throws {
        let e = try DEnv()
        let l = e.inetSocket()
        e.bindInet(l, sockaddrIn([127, 0, 0, 1], port: 0))
        e.call(106, [UInt64(l), 4])
        let c = e.inetSocket()
        e.setNonBlocking(c)
        _ = e.connectInet(c, sockaddrIn([127, 0, 0, 1], port: e.port(l)))
        let kq = e.call(362).fd
        var change = [UInt8](repeating: 0, count: 32)
        change.putLE(UInt64(c), at: 0)
        change.putLE(Int16(-13), at: 8)                // EVFILT_SOCK
        change.putLE(UInt16(0x1), at: 10)              // EV_ADD
        change.putLE(SocketEvents.connected | SocketEvents.readClosed | SocketEvents.connReset, at: 12)
        e.put(change, at: bufVA + 0x1000)
        var ts: [UInt8] = []
        ts.appendLE(Int64(5)); ts.appendLE(Int64(0))
        e.put(ts, at: bufVA + 0x1100)
        var zero: [UInt8] = []
        zero.appendLE(Int64(0)); zero.appendLE(Int64(0))
        e.put(zero, at: bufVA + 0x1180)
        let n = e.call(363, [UInt64(kq), bufVA + 0x1000, 1, bufVA + 0x1200, 1, bufVA + 0x1100])
        let ev = e.get(bufVA + 0x1200, 32)
        #expect(n.value == 1 && ev.readLE(Int16.self, at: 8) == -13)
        #expect(ev.readLE(UInt32.self, at: 12) == SocketEvents.connected && ev.readLE(Int64.self, at: 16) == 1)
        // A level event is reported once.
        #expect(e.call(363, [UInt64(kq), 0, 0, bufVA + 0x1200, 1, bufVA + 0x1180]).value == 0)
        // The peer closes: NOTE_READCLOSED with EV_EOF.
        put0(e)
        let s = e.call(30, [UInt64(l), addrVA, lenVA]).fd
        e.close(s)
        let m = e.call(363, [UInt64(kq), 0, 0, bufVA + 0x1200, 1, bufVA + 0x1100])
        let ev2 = e.get(bufVA + 0x1200, 32)
        #expect(m.value == 1 && ev2.readLE(UInt32.self, at: 12) & SocketEvents.readClosed != 0)
        #expect(ev2.readLE(UInt16.self, at: 10) & 0x8000 != 0)  // EV_EOF
        e.close(c)
        e.close(l)
        e.close(kq)
    }

    @Test func blockingAcceptAndReceiveWakeOnTheHost() throws {
        let e = try DEnv()
        let l = e.inetSocket()
        e.bindInet(l, sockaddrIn([127, 0, 0, 1], port: 0))
        e.call(106, [UInt64(l), 4])
        let port = e.port(l)
        // A host client connects and writes after the guest blocks.
        let client = HostThread { () -> Int32 in
            usleep(200_000)
            #if canImport(Glibc)
            let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
            #else
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            #endif
            let a = InetAddress.ipv4(127, 0, 0, 1, port: port).hostBytes(hostScope: 0)
            _ = HostSocketCalls.withAddress(a) { connect(fd, $0, $1) }
            usleep(200_000)
            _ = "late".withCString { send(fd, $0, 4, 0) }
            usleep(200_000)
            return fd
        }
        put0(e)
        let a = e.call(30, [UInt64(l), addrVA, lenVA])
        #expect(!a.carry)
        let (r, bytes) = e.receiveBytes(a.fd)
        #expect(r.value == 4 && bytes == Array("late".utf8))
        if let fd = client.wait() { _ = Glibc_close(fd) }
        e.close(a.fd)
        e.close(l)
    }

    @Test func udpDatagramsAndOptions() throws {
        let e = try DEnv()
        let a = e.inetSocket(2, 2), b = e.inetSocket(2, 2)
        e.bindInet(a, sockaddrIn([127, 0, 0, 1], port: 0))
        let port = e.port(a)
        #expect(e.setInetOption(a, 0, UInt32(InetABI.ipRecvDstAddr), int32Bytes(1)).value == 0)
        #expect(e.getInetOption(a, 0, UInt32(InetABI.ipRecvDstAddr)).1 == int32Bytes(1))
        e.put(sockaddrIn([127, 0, 0, 1], port: port), at: addrVA)
        e.put(Array("0123456789".utf8), at: bufVA)
        #expect(e.call(133, [UInt64(b), bufVA, 10, 0, addrVA, 16]).value == 10)
        // recvmsg with a 4-byte buffer: MSG_TRUNC, the sender's address, IP_RECVDSTADDR.
        var iov: [UInt8] = []
        iov.appendLE(bufVA + 0x8000); iov.appendLE(UInt64(4))
        e.put(iov, at: bufVA + 0x100)
        var h = [UInt8](repeating: 0, count: 48)
        h.putLE(bufVA + 0x200, at: 0); h.putLE(UInt32(28), at: 8)
        h.putLE(bufVA + 0x100, at: 16); h.putLE(Int32(1), at: 24)
        h.putLE(bufVA + 0x300, at: 32); h.putLE(UInt32(64), at: 40)
        e.put(h, at: bufVA + 0x400)
        #expect(e.poll(a, events: 1, timeout: 2000).0 == 1)
        let r = e.call(27, [UInt64(a), bufVA + 0x400, 0])
        #expect(r.value == 4)
        #expect(e.get(bufVA + 0x8000, 4) == Array("0123".utf8))
        #expect(e.i32(bufVA + 0x400 + 44) & InetABI.msgTrunc != 0)
        #expect(e.u32(bufVA + 0x400 + 8) == 16 && e.get(bufVA + 0x200 + 1, 1) == [2])
        let cl = e.u32(bufVA + 0x400 + 40)
        #expect(cl == 16 && e.i32(bufVA + 0x300 + 8) == InetABI.ipRecvDstAddr && e.get(bufVA + 0x300 + 12, 4) == [127, 0, 0, 1])
        // sendto without an address on an unconnected datagram socket.
        #expect(e.sendBytes(b, [1]).errno == 39)  // EDESTADDRREQ
        // A Darwin-only option is kept and read back; get-only options refuse a set.
        #expect(e.setInetOption(a, 0xFFFF, 0x1116, int32Bytes(4)).value == 0)
        #expect(e.getInetOption(a, 0xFFFF, 0x1116).1 == int32Bytes(4))
        #expect(e.setInetOption(a, 0xFFFF, UInt32(InetABI.soType), int32Bytes(1)).errno == DarwinErrnoCode.ENOPROTOOPT)
        // socketpair of an IP domain: EOPNOTSUPP; an unknown type: EPROTOTYPE.
        #expect(e.call(135, [2, 1, 0, bufVA]).errno == DarwinErrnoCode.EOPNOTSUPP)
        #expect(e.call(97, [2, 9, 0]).errno == DarwinErrnoCode.EPROTOTYPE)
        e.close(a)
        e.close(b)
    }

    @Test func pollWithAHostFileAndAClosedDescriptor() throws {
        let e = try DEnv()
        var p: [UInt8] = []
        p.appendLE(Int32(1)); p.appendLE(Int16(4)); p.appendLE(Int16(0))     // stdout: writable
        p.appendLE(Int32(77)); p.appendLE(Int16(1)); p.appendLE(Int16(0))    // not open: POLLNVAL
        p.appendLE(Int32(-1)); p.appendLE(Int16(1)); p.appendLE(Int16(0))    // skipped
        e.put(p, at: bufVA)
        let r = e.call(230, [bufVA, 3, 0])
        #expect(r.value == 2)
        let out = e.get(bufVA, 24)
        #expect(out.readLE(Int16.self, at: 6) == 4 && out.readLE(Int16.self, at: 14) == 0x20 && out.readLE(Int16.self, at: 22) == 0)
        // A timeout with nothing ready.
        let (a, b) = e.pipe()
        let t0 = KernelClock.now()
        #expect(e.poll(a, events: 1, timeout: 50).0 == 0)
        #expect(KernelClock.now() - t0 >= 40_000_000)
        e.write(b, "x")
        #expect(e.poll(a, events: 1, timeout: 50).0 == 1)
    }

    // MARK: Snapshots

    /// networking-ycode.md §6: a listener and a bound UDP socket come back
    /// on their ports; a connection is reset.
    @Test func snapshotRestoresListenersAndResetsConnections() throws {
        let e = try ProcEnv()
        let k = e.rootKernel!
        let s = ProcEnv.scratch
        func sa(_ port: UInt16) -> [UInt8] { sockaddrIn([127, 0, 0, 1], port: port) }
        func port(_ fd: Int64) -> UInt16 {
            e.put(k, [16, 0, 0, 0], at: s + 0x110)
            _ = e.bsd(k, 32, [UInt64(fd), s + 0x100, s + 0x110])
            let b = e.read(k, s + 0x100, 4)
            return UInt16(b[2]) << 8 | UInt16(b[3])
        }
        let l = e.bsd(k, 97, [2, 1, 0])
        e.put(k, sa(0), at: s + 0x200)
        #expect(e.bsd(k, 104, [UInt64(l), s + 0x200, 16]) == 0)
        #expect(e.bsd(k, 106, [UInt64(l), 4]) == 0)
        let lport = port(l)
        let c = e.bsd(k, 97, [2, 1, 0])
        e.put(k, sa(lport), at: s + 0x200)
        #expect(e.bsd(k, 98, [UInt64(c), s + 0x200, 16]) == 0)
        let u = e.bsd(k, 97, [2, 2, 0])
        e.put(k, sa(0), at: s + 0x200)
        #expect(e.bsd(k, 104, [UInt64(u), s + 0x200, 16]) == 0)
        let uport = port(u)

        let records: [SnapshotRecord] = e.system.lock.withLock {
            let capture = KernelSnapshotCapture(system: e.system, classification: SnapshotClassification())
            capture.capture(images: [SnapshotImageInput(kernel: k, parked: [:], fpState: { _ in nil })],
                            guestCounter: 1000, frequency: 24_000_000, bootCounter: 10)
            #expect(capture.counts["IP socket"] == 3)
            // (The test's main thread is in no restorable state; that is all.)
            #expect(capture.unsupported.keys.allSatisfy { !$0.contains("descriptor") && !$0.contains("socket") && !$0.contains("knote") })
            return capture.records
        }
        // The original process goes away (its ports are free again).
        e.system.terminateAllProcesses()
        for fd in [l, c, u] { _ = e.bsd(k, 6, [UInt64(fd)]) }
        let (_, decoded) = try SnapshotManifest.decode(SnapshotManifest.encode(records))
        let system = DarwinSystem()
        system.launcher = FakeLauncher()
        let restore = try KernelSnapshotRestore(records: decoded, system: system)
        let plans = try restore.makeProcesses {
            DarwinFileSystem(prefixes: [.init(guestPath: e.root, hostPath: e.root, writable: true)], console: { _, _ in })
        }
        let k2 = plans[0].kernel
        let space = GuestAddressSpace(backing: FakePhysicalBacking())
        _ = try space.mapAnonymous(at: s, size: ProcEnv.scratchSize, protection: .readWrite, hint: nil)
        _ = try restore.restoreObjects { _ in space }
        #expect(!restore.warnings.contains { $0.contains("IP socket") })
        func call(_ n: Int64, _ args: [UInt64]) -> (UInt64, Bool) {
            var f = TrapFrame()
            f.kind = TrapFrame.Kind.svc.rawValue
            f.x[16] = UInt64(bitPattern: n)
            for (i, v) in args.enumerated() { f.x[i] = v }
            _ = k2.handle(&f, context: k2.mainThread, memory: space)
            return (f.x[0], f.carry)
        }
        // The listener listens on its port again: a host client connects and is accepted.
        #if canImport(Glibc)
        let host = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #else
        let host = socket(AF_INET, SOCK_STREAM, 0)
        #endif
        defer { _ = Glibc_close(host) }
        let a = InetAddress.ipv4(127, 0, 0, 1, port: lport).hostBytes(hostScope: 0)
        #expect(HostSocketCalls.withAddress(a) { connect(host, $0, $1) } == 0)
        let accepted = call(30, [UInt64(l), 0, 0])
        #expect(!accepted.1)
        // The connection was reset: ECONNRESET once, then end of stream.
        let r1 = call(3, [UInt64(c), s + 0x300, 16])
        #expect(r1.1 && Int32(r1.0) == DarwinErrnoCode.ECONNRESET)
        let r2 = call(3, [UInt64(c), s + 0x300, 16])
        #expect(!r2.1 && r2.0 == 0)
        // The UDP socket is bound to its port again.
        try system.lock.withLock { try space.write(va: s + 0x110, bytes: [16, 0, 0, 0]) }
        _ = call(32, [UInt64(u), s + 0x100, s + 0x110])
        let b = try system.lock.withLock { try space.read(va: s + 0x100, count: 4) }
        #expect(UInt16(b[2]) << 8 | UInt16(b[3]) == uport)
        system.terminateAllProcesses()
    }

    // MARK: DNS service

    @Test func dnsServiceOverTheUnixSocket() throws {
        HostResolver.addressOverride = { name, ipv6 in
            guard name == "host.test" else { return nil }
            return ipv6 ? [] : [[192, 0, 2, 7]]
        }
        HostResolver.queryOverride = { name, type, _ in
            .records([HostResolver.Record(name: name + ".", type: type, rrclass: 1, ttl: 30, rdata: [1, 2, 3])])
        }
        defer {
            HostResolver.addressOverride = nil
            HostResolver.queryOverride = nil
        }
        let e = try DEnv()
        let s = e.socket()
        #expect(e.connect(s, "/var/run/mDNSResponder").value == 0)
        // getaddrinfo request on its own connection: the status first, then the answers.
        let ctx: [UInt8] = [9, 8, 7, 6, 5, 4, 3, 2]
        var data: [UInt8] = []
        data.appendBE32(0); data.appendBE32(0); data.appendBE32(3)
        data += Array("host.test".utf8) + [0]
        let request = DNSServiceIPC.Header(datalen: UInt32(data.count), op: DNSServiceIPC.Op.addrInfo, context: ctx).bytes + data
        #expect(e.sendBytes(s, request).value == UInt64(request.count))
        var received: [UInt8] = []
        let deadline = KernelClock.deadline(afterNanoseconds: 5_000_000_000)
        while KernelClock.now() < deadline {
            _ = e.poll(s, events: 1, timeout: 200)
            e.setNonBlocking(s)
            let (r, bytes) = e.receiveBytes(s)
            if r.value != nil { received += bytes }
            if received.count >= 4 + 2 * 28 + 24 { break }
        }
        #expect(received.readBE32(at: 0) == 0)
        // Answer 1: A 192.0.2.7, more coming; answer 2: AAAA, no such record.
        var off = 4
        let h1 = DNSServiceIPC.Header(received[off..<(off + 28)])
        #expect(h1.op == DNSServiceIPC.Op.addrInfoReply && h1.context == ctx)
        let body1 = Array(received[(off + 28)..<(off + 28 + Int(h1.datalen))])
        #expect(body1.readBE32(at: 0) == DNSServiceIPC.add | DNSServiceIPC.moreComing && body1.readBE32(at: 8) == 0)
        #expect(Array(body1.suffix(8)) == [192, 0, 2, 7, 0, 0, 0, 60])
        off += 28 + Int(h1.datalen)
        let h2 = DNSServiceIPC.Header(received[off..<(off + 28)])
        let body2 = Array(received[(off + 28)..<(off + 28 + Int(h2.datalen))])
        #expect(Int32(bitPattern: body2.readBE32(at: 8)) == DNSServiceIPC.noSuchRecord && body2.readBE32(at: 0) == DNSServiceIPC.add)

        // A shared connection: connection_request, then a subordinate query
        // whose status goes to a socket passed with SCM_RIGHTS.
        let shared = e.socket()
        #expect(e.connect(shared, "/var/run/mDNSResponder").value == 0)
        let open = DNSServiceIPC.Header(datalen: 0, op: DNSServiceIPC.Op.connection, context: [0, 0, 0, 0, 0, 0, 0, 1]).bytes
        #expect(e.sendBytes(shared, open).value == 28)
        e.setNonBlocking(shared)
        #expect(e.receiveBytes(shared).1 == [0, 0, 0, 0])
        #expect(!e.call(135, [1, 1, 0, bufVA + 0x9F00]).carry)
        let errA = e.i32(bufVA + 0x9F00), errB = e.i32(bufVA + 0x9F04)
        var q: [UInt8] = [0]                       // empty return path
        q.appendBE32(0); q.appendBE32(0)
        q += Array("x.test".utf8) + [0]
        q.appendBE16(65); q.appendBE16(1)
        let subCtx: [UInt8] = [0, 0, 0, 0, 0, 0, 0, 2]
        let sub = DNSServiceIPC.Header(datalen: UInt32(q.count), op: DNSServiceIPC.Op.query, context: subCtx).bytes + q
        #expect(e.sendBytes(shared, Array(sub.dropLast())).value == UInt64(sub.count - 1))
        // The last byte travels with the error-return socket.
        let base = DEnv.scratch + 0x8000
        e.put([sub.last!], at: base + 0x100)
        e.put(leBytes(base + 0x100) + leBytes(UInt64(1)), at: base + 0x80)
        var c: [UInt8] = []
        c.appendLE(UInt32(16)); c.appendLE(Int32(0xFFFF)); c.appendLE(Int32(1)); c.appendLE(errB)
        e.put(c, at: base + 0x200)
        var hh = [UInt8](repeating: 0, count: 48)
        hh.putLE(base + 0x80, at: 16); hh.putLE(Int32(1), at: 24); hh.putLE(base + 0x200, at: 32); hh.putLE(UInt32(16), at: 40)
        e.put(hh, at: base)
        #expect(e.call(28, [UInt64(shared), base, 0]).value == 1)
        e.close(errB)
        e.setNonBlocking(errA)
        #expect(e.receiveBytes(errA).1 == [0, 0, 0, 0])
        var answer: [UInt8] = []
        while KernelClock.now() < deadline, answer.count < 28 {
            _ = e.poll(shared, events: 1, timeout: 200)
            let (r, bytes) = e.receiveBytes(shared)
            if r.value != nil { answer += bytes }
        }
        let h3 = DNSServiceIPC.Header(answer[0..<28])
        #expect(h3.op == DNSServiceIPC.Op.queryReply && h3.context == subCtx)
        #expect(Array(answer.suffix(9)) == [0, 3, 1, 2, 3, 0, 0, 0, 30])
        e.close(errA)
        e.close(shared)
        e.close(s)
    }
}

private func Glibc_close(_ fd: Int32) -> Int32 { close(fd) }

private extension Array where Element == UInt8 {
    mutating func putBE16(_ v: UInt16, at offset: Int) {
        self[offset] = UInt8(v >> 8)
        self[offset + 1] = UInt8(v & 0xFF)
    }
}
