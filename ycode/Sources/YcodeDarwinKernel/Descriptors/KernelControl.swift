import Foundation
import YcodeDarwinABI
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

// Kernel control sockets (`specs/simulator/networking-ycode.md` §3.4):
// `socket(PF_SYSTEM, SOCK_DGRAM, SYSPROTO_CONTROL)`, CTLIOCGINFO to find a
// control by name, `connect` with a `sockaddr_ctl`, then datagrams. The one
// control Ycode provides is `com.apple.netsrc` (xnu `netsrc.h`), which
// `getaddrinfo` and Network.framework ask for the source address and
// interface of a destination (`networking.md` §3.7). Any other name:
// CTLIOCGINFO fails with ENOENT, as for a control nobody registered.
//
// netsrc: a 36-byte request (version 1 or 2, interface scope, the
// destination as a `sockaddr_in`/`sockaddr_in6` in a 28-byte union) gets a
// reply: version 2, 56 bytes (source address union, minimum RTT, connection
// attempts and successes — 0 here —, flags, the RFC 6724 label and
// precedence of source and destination, the interface index); version 1,
// 40 bytes (source, IPv6 flags, labels, precedences). The source address is
// the one the host would use (a host UDP socket connected to the
// destination); the interface is the guest's route to it (§3.3).

final class KernelControlSocket: KernelDescriptorObject {
    let lock: KernelLock
    let signals = ObjectSignals()
    let inode = DescriptorInodes.make()
    var connectedID: UInt32 = 0
    var queue: [[UInt8]] = []
    var options: [Int32: [UInt8]] = [:]

    static let afSystem: Int32 = 32, sysprotoControl: Int32 = 2, afSysControl: UInt16 = 2
    static let netsrcName = "com.apple.netsrc"
    static let netsrcID: UInt32 = 0x7963_0001
    /// `CTLIOCGINFO` = `_IOWR('N', 3, struct ctl_info)` (100 bytes).
    static let ctliocginfo: UInt32 = 0xC064_4E03

    init(lock: KernelLock) { self.lock = lock }

    var fileType: UInt16 { DarwinStat.S_IFSOCK }

    func lastReferenceClosed() {
        lock.withLock {
            queue = []
            signals.fire()
        }
    }

    func readReadiness() -> (ready: Bool, data: Int64, eof: Bool) { (!queue.isEmpty, Int64(queue.first?.count ?? 0), false) }
    func writeReadiness() -> (ready: Bool, data: Int64, eof: Bool) { (connectedID != 0, 8192, false) }
    func addReadinessObserver(_ observer: @escaping () -> Void) -> Int { signals.addObserver(observer) }
    func removeReadinessObserver(_ token: Int) { signals.removeObserver(token) }

    // MARK: netsrc

    /// The RFC 6724 default policy (label, precedence) of an IPv6 address
    /// (IPv4 as IPv4-mapped).
    static func policy(_ a: [UInt8]) -> (label: UInt16, precedence: UInt16) {
        if a.count == 4 { return (4, 35) }
        func prefix(_ p: [UInt8], _ bits: Int) -> Bool {
            for i in 0..<(bits / 8) where a[i] != p[i] { return false }
            let rest = bits % 8
            return rest == 0 || (a[bits / 8] & UInt8(0xFF << (8 - rest))) == (p[bits / 8] & UInt8(0xFF << (8 - rest)))
        }
        let z = [UInt8](repeating: 0, count: 16)
        if a == z.prefix(15) + [1] { return (0, 50) }
        if prefix(z.prefix(10) + [0xFF, 0xFF] + [0, 0, 0, 0], 96) { return (4, 35) }
        if prefix([0x20, 0x02] + z.prefix(14), 16) { return (2, 30) }
        if prefix([0x20, 0x01, 0, 0] + z.prefix(12), 32) { return (5, 5) }
        if prefix([0xFC] + z.prefix(15), 7) { return (13, 3) }
        if prefix(z, 96) { return (3, 1) }
        if prefix([0xFE, 0xC0] + z.prefix(14), 10) { return (11, 1) }
        if prefix([0x3F, 0xFE] + z.prefix(14), 16) { return (12, 1) }
        return (1, 40)
    }

    /// The source address the host would use toward `dst` (nil: no route).
    static func hostSource(for dst: InetAddress) -> [UInt8]? {
        let family = dst.isIPv4 ? HostNet.afInet : HostNet.afInet6
        #if canImport(Glibc)
        let fd = socket(family, Int32(SOCK_DGRAM.rawValue), 0)
        #else
        let fd = socket(family, SOCK_DGRAM, 0)
        #endif
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var target = dst
        if target.port == 0 { target.port = 9 }
        let bytes = target.hostBytes(hostScope: NetworkInterfaces.hostIndex(dst.scope))
        guard HostSocketCalls.withAddress(bytes, { connect(fd, $0, $1) }) == 0,
              let raw = HostSocketCalls.name(fd, peer: false),
              let a = InetAddress.fromHost(raw, guestScope: NetworkInterfaces.guestIndex) else { return nil }
        return a.address
    }

    /// The reply to a netsrc request (nil for a malformed one).
    static func netsrcReply(_ req: [UInt8]) -> [UInt8]? {
        guard req.count >= 8 + 16 else { return nil }
        let version = req.readLE(UInt32.self, at: 0)
        guard version == 1 || version == 2 else { return nil }
        let sa = Array(req[8...])
        let family = Int32(sa.count > 1 ? sa[1] : 0)
        guard let dst = try? InetAddress.fromDarwin(sa, domain: family) else { return nil }
        let route = RouteSocket.bestRoute(family: family, to: dst.address)
        var source: [UInt8]?
        if route != nil { source = hostSource(for: dst) }
        var src = [UInt8](repeating: 0, count: 28)
        if let source {
            let s = InetAddress(family: family, port: 0, address: source).darwinBytes
            src.replaceSubrange(0..<s.count, with: s)
        }
        let srcPolicy: (label: UInt16, precedence: UInt16) = source.map(policy) ?? (0, 0)
        let dstPolicy = policy(dst.address)
        var out = src
        if version == 2 {
            out.appendLE(UInt32(0)); out.appendLE(UInt32(0)); out.appendLE(UInt32(0))
            out.appendLE(UInt32(route != nil && source != nil ? 0x20 : 0))  // NETSRC_FLAG_ROUTEABLE
            out.appendLE(srcPolicy.label); out.appendLE(srcPolicy.precedence)
            out.appendLE(dstPolicy.label); out.appendLE(dstPolicy.precedence)
            out.appendLE(UInt16(truncatingIfNeeded: route?.index ?? 0))
            out.appendLE(UInt16(0))
        } else {
            out.appendLE(UInt16(0))
            out.appendLE(srcPolicy.label); out.appendLE(srcPolicy.precedence)
            out.appendLE(dstPolicy.label); out.appendLE(dstPolicy.precedence)
            out.appendLE(UInt16(0))
        }
        return out
    }
}

extension DarwinKernel {
    /// Socket calls on a kernel control socket.
    func kernelControlCall(_ n: Int, _ a: [UInt64], _ s: KernelControlSocket, _ file: DarwinOpenFile, _ call: inout CallText,
                           _ mem: any KernelGuestMemory) throws -> BSDResult {
        func int(_ i: Int) -> Int32 { Int32(truncatingIfNeeded: a[i]) }
        switch n {
        case DescriptorBSD.connect:
            // struct sockaddr_ctl: len, family, ss_sysaddr u16, sc_id u32, sc_unit u32, reserved.
            let length = Int(UInt32(truncatingIfNeeded: a[2]))
            guard length >= 12, length <= 255 else { throw fail(Code.EINVAL) }
            let sa = try mem.read(va: a[1], count: length)
            guard Int32(sa[1]) == KernelControlSocket.afSystem else { throw fail(Code.EAFNOSUPPORT) }
            let id = sa.readLE(UInt32.self, at: 4)
            guard id == KernelControlSocket.netsrcID else { throw fail(DarwinErrnoCode.ENOENT) }
            if s.connectedID != 0 { throw fail(Code.EISCONN) }
            s.connectedID = id
            call += " [\(KernelControlSocket.netsrcName)]"
            s.signals.fire()
            return .value(0)
        case DescriptorBSD.sendto, DescriptorBSD.sendmsg:
            var bytes: [UInt8]
            if n == DescriptorBSD.sendto {
                guard a[2] <= 4096 else { throw fail(Code.EMSGSIZE) }
                bytes = a[2] == 0 ? [] : try mem.read(va: a[1], count: Int(a[2]))
            } else {
                let h = try mem.read(va: a[1], count: 48)
                bytes = try gather(try readIOVec(h.readLE(UInt64.self, at: 16), count: h.readLE(Int32.self, at: 24), mem,
                                                 limitError: Code.EMSGSIZE), mem)
            }
            return .value(UInt64(try kernelControlWrite(s, bytes)))
        case DescriptorBSD.recvfrom, DescriptorBSD.recvmsg:
            let flags = n == DescriptorBSD.recvfrom ? int(3) : int(2)
            let m = try kernelControlRead(s, file, flags: flags)
            if n == DescriptorBSD.recvfrom {
                let count = min(m.count, Int(a[2]))
                if count > 0 { try mem.write(va: a[1], bytes: Array(m.prefix(count))) }
                if a[4] != 0 { try copyOutAddress(nil, to: a[4], lengthPointer: a[5], mem) }
                return .value(UInt64(count))
            }
            let h = try mem.read(va: a[1], count: 48)
            let iov = try readIOVec(h.readLE(UInt64.self, at: 16), count: h.readLE(Int32.self, at: 24), mem, limitError: Code.EMSGSIZE)
            let total = iov.reduce(0) { $0 + Int($1.length) }
            try scatter(Array(m.prefix(total)), into: iov, mem)
            try writeU32(a[1] + 8, 0, mem)
            try writeU32(a[1] + 40, 0, mem)
            try writeU32(a[1] + 44, UInt32(bitPattern: m.count > total ? InetABI.msgTrunc : 0), mem)
            return .value(UInt64(min(m.count, total)))
        case DescriptorBSD.setsockopt:
            let size = Int(UInt32(truncatingIfNeeded: a[4]))
            s.options[int(2)] = a[3] == 0 || size == 0 ? [] : try mem.read(va: a[3], count: min(size, 256))
            return .value(0)
        case DescriptorBSD.getsockopt:
            guard a[4] != 0 else { throw fail(Code.EFAULT) }
            var value: [UInt8] = []
            if int(1) == InetABI.solSocket, int(2) == InetABI.soType { value.appendLE(InetABI.sockDgram) } else {
                value = s.options[int(2)] ?? [0, 0, 0, 0]
            }
            let room = Int(try mem.read(va: a[4], count: 4).readLE(UInt32.self, at: 0))
            let count = min(room, value.count)
            if a[3] != 0, count > 0 { try mem.write(va: a[3], bytes: Array(value.prefix(count))) }
            try writeU32(a[4], UInt32(count), mem)
            return .value(0)
        case DescriptorBSD.shutdown:
            return .value(0)
        default:
            throw fail(Code.EOPNOTSUPP)
        }
    }

    func kernelControlWrite(_ s: KernelControlSocket, _ bytes: [UInt8]) throws -> Int {
        guard s.connectedID != 0 else { throw fail(Code.ENOTCONN) }
        guard let reply = KernelControlSocket.netsrcReply(bytes) else { throw fail(Code.EINVAL) }
        s.queue.append(reply)
        s.signals.fire()
        return bytes.count
    }

    func kernelControlRead(_ s: KernelControlSocket, _ file: DarwinOpenFile, flags: Int32) throws -> [UInt8] {
        while true {
            if flags & InetABI.msgPeek != 0, let m = s.queue.first { return m }
            if !s.queue.isEmpty { return s.queue.removeFirst() }
            if file.isNonBlocking || flags & InetABI.msgDontWait != 0 { throw fail(Code.EAGAIN) }
            _ = try waitOnObject(s.signals, deadline: nil)
        }
    }

    /// CTLIOCGINFO: the control id of a name.
    func kernelControlInfo(_ a: [UInt64], _ mem: any KernelGuestMemory) throws -> BSDResult {
        var info = try mem.read(va: a[2], count: 100)
        let name = String(decoding: info[4...].prefix { $0 != 0 }, as: UTF8.self)
        guard name == KernelControlSocket.netsrcName else { throw fail(DarwinErrnoCode.ENOENT) }
        info.putLE(KernelControlSocket.netsrcID, at: 0)
        try mem.write(va: a[2], bytes: info)
        return .value(0)
    }
}
