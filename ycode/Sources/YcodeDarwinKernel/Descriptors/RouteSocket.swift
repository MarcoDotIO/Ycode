import Foundation
import YcodeDarwinABI

// PF_ROUTE sockets (`specs/simulator/networking-ycode.md` §3.3): the routing
// socket a process opens to ask the kernel which route (and interface) a
// destination takes. Network.framework does this for every path it
// evaluates (`socket(PF_ROUTE, SOCK_RAW, PF_ROUTE)`, an RTM_GET message,
// then a read of the answer); without it every path is unsatisfied ("No
// network route").
//
// A write of an RTM_GET (or RTM_GET_SILENT, RTM_GET_EXT) message looks the
// destination up in the guest's routing table (`NetworkInterfaces.routes`,
// longest prefix) and queues the answer for reading on the same socket (as
// SO_USELOOPBACK, on by default, does): an RTM_GET message (also for
// RTM_GET_SILENT, networking.md §3.6) with the request's sequence, the
// writer's pid, the route's flags (plus RTF_DONE), its interface index, the
// MTU, no error, and the
// route's destination, gateway (an address, or the interface's link
// address) and mask, plus the interface's link address and its address of
// the destination's family when the request named RTA_IFP or RTA_IFA. No
// route: the write fails with ESRCH and the message comes back with that
// errno. Messages that change the table fail with EPERM (the guest is not
// privileged). Nothing else is ever sent on the socket (no interface or
// address change messages).

final class RouteSocket: KernelDescriptorObject {
    let lock: KernelLock
    let signals = ObjectSignals()
    let inode = DescriptorInodes.make()
    let proto: Int32
    private(set) var queue: [[UInt8]] = []
    var shutRead = false
    var shutWrite = false
    var options: [Int32: [UInt8]] = [:]
    /// Statistics.
    nonisolated(unsafe) static var lookups = 0

    static let rtmVersion: UInt8 = 5
    static let rtmGet: UInt8 = 4, rtmGetSilent: UInt8 = 0x11, rtmGetExt: UInt8 = 0x15
    static let rtfDone: Int32 = 0x40
    static let rtaDst: Int32 = 0x1, rtaGateway: Int32 = 0x2, rtaNetmask: Int32 = 0x4, rtaGenmask: Int32 = 0x8,
               rtaIFP: Int32 = 0x10, rtaIFA: Int32 = 0x20, rtaAuthor: Int32 = 0x40, rtaBrd: Int32 = 0x80
    static let headerSize = 92
    static let esrch: Int32 = 3

    init(proto: Int32, lock: KernelLock) {
        self.proto = proto
        self.lock = lock
    }

    var fileType: UInt16 { DarwinStat.S_IFSOCK }

    func lastReferenceClosed() {
        lock.withLock {
            queue = []
            signals.fire()
        }
    }

    func readReadiness() -> (ready: Bool, data: Int64, eof: Bool) {
        (!queue.isEmpty || shutRead, Int64(queue.first?.count ?? 0), shutRead)
    }

    func writeReadiness() -> (ready: Bool, data: Int64, eof: Bool) { (true, 8192, shutWrite) }
    func addReadinessObserver(_ observer: @escaping () -> Void) -> Int { signals.addObserver(observer) }
    func removeReadinessObserver(_ token: Int) { signals.removeObserver(token) }

    func takeMessage() -> [UInt8]? {
        guard !queue.isEmpty else { return nil }
        return queue.removeFirst()
    }

    /// A message written by the guest (pid `pid`). Returns the errno for
    /// the writer (0 = accepted).
    func write(_ m: [UInt8], pid: Int32) -> Int32 {
        guard m.count >= Self.headerSize, Int(m.readLE(UInt16.self, at: 0)) <= m.count else { return DarwinErrnoCode.EINVAL }
        guard m[2] == Self.rtmVersion else { return 43 }  // EPROTONOSUPPORT
        let type = m[3]
        guard type == Self.rtmGet || type == Self.rtmGetSilent || type == Self.rtmGetExt else { return DarwinErrnoCode.EPERM }
        let (reply, error) = Self.answer(m, pid: pid)
        if type != Self.rtmGetSilent || error == 0 {
            queue.append(reply)
            signals.fire()
        }
        return error
    }

    /// The sockaddrs of a message, by RTA bit.
    static func addresses(_ m: [UInt8], addrs: Int32, from offset: Int) -> [Int32: [UInt8]] {
        var out: [Int32: [UInt8]] = [:]
        var off = offset
        for bit in 0..<8 where addrs & (1 << Int32(bit)) != 0 {
            guard off < m.count else { break }
            let len = Int(m[off])
            let size = len == 0 ? 4 : (len + 3) & ~3
            out[1 << Int32(bit)] = Array(m[off..<min(m.count, off + max(len, 1))])
            off += size
        }
        return out
    }

    /// The answer to an RTM_GET and its errno.
    static func answer(_ m: [UInt8], pid: Int32) -> ([UInt8], Int32) {
        lookups += 1
        var header = Array(m.prefix(headerSize))
        header.putLE(pid, at: 16)
        let addrs = m.readLE(Int32.self, at: 12)
        let given = addresses(m, addrs: addrs, from: headerSize)
        func fail(_ e: Int32) -> ([UInt8], Int32) {
            var r = Array(m.prefix(Int(m.readLE(UInt16.self, at: 0))))
            r.putLE(pid, at: 16)
            r.putLE(e, at: 24)
            return (r, e)
        }
        guard let dst = given[rtaDst], dst.count >= 2 else { return fail(DarwinErrnoCode.EINVAL) }
        let family = Int32(dst[1])
        let target: [UInt8]
        if family == InetABI.afInet, dst.count >= 8 {
            target = Array(dst[4..<8])
        } else if family == InetABI.afInet6, dst.count >= 24 {
            target = Array(dst[8..<24])
        } else {
            return fail(DarwinErrnoCode.EAFNOSUPPORT)
        }
        guard let route = bestRoute(family: family, to: target) else { return fail(esrch) }
        let sa: ([UInt8]) -> [UInt8] = family == InetABI.afInet ? { NetworkInterfaces.sockaddrIn($0) } : { NetworkInterfaces.sockaddrIn6($0) }
        let interface = NetworkInterfaces.interface(index: route.index)
        let link = NetworkInterfaces.sockaddrDL(index: route.index, name: interface?.name ?? "", type: interface?.type ?? 0,
                                                address: interface?.linkAddress ?? [])
        var out: [Int32: [UInt8]] = [rtaDst: sa(route.destination), rtaGateway: route.gateway.map(sa) ?? link]
        // A zero mask (a default route) is an empty sockaddr, as xnu stores it.
        if let mask = route.netmask { out[rtaNetmask] = mask.allSatisfy { $0 == 0 } ? [0, 0, 0, 0] : sa(mask) }
        if addrs & (rtaIFP | rtaIFA) != 0 {
            out[rtaIFP] = link
            let own: [UInt8]? = family == InetABI.afInet ? interface?.ipv4.first?.address
                : (interface?.ipv6.first { !NetworkInterfaces.isLinkLocal($0.address) } ?? interface?.ipv6.first)?.address
            if let own { out[rtaIFA] = sa(own) }
        }
        var replyAddrs: Int32 = 0
        var body: [UInt8] = []
        for bit in 0..<8 {
            let b = Int32(1) << Int32(bit)
            guard let s = out[b] else { continue }
            replyAddrs |= b
            body += s
            while body.count % 4 != 0 { body.append(0) }
        }
        // The answer to RTM_GET and RTM_GET_SILENT is an RTM_GET message.
        if header[3] == rtmGetSilent { header[3] = rtmGet }
        header.putLE(UInt16(route.index), at: 4)
        header.putLE(route.flags | rtfDone, at: 8)
        header.putLE(replyAddrs, at: 12)
        header.putLE(Int32(0), at: 24)
        header.putLE(interface?.mtu ?? 1500, at: 36 + 4)  // rmx_mtu
        let reply = header + body
        var r = reply
        r.putLE(UInt16(reply.count), at: 0)
        return (r, 0)
    }

    /// The longest-prefix route of the guest's table for `target`.
    static func bestRoute(family: Int32, to target: [UInt8]) -> NetworkInterfaces.Route? {
        var best: (NetworkInterfaces.Route, Int)?
        for (f, r) in NetworkInterfaces.routes(family: family) where f == family {
            let mask = r.netmask ?? [UInt8](repeating: 0xFF, count: target.count)
            guard mask.count == target.count, r.destination.count == target.count else { continue }
            let matches = zip(zip(target, mask), r.destination).allSatisfy { ($0.0 & $0.1) == ($1 & $0.1) }
            guard matches else { continue }
            let length = mask.reduce(0) { $0 + $1.nonzeroBitCount }
            if best == nil || length > best!.1 { best = (r, length) }
        }
        return best?.0
    }
}

extension DarwinKernel {
    /// Socket calls on a PF_ROUTE socket.
    func routeSocketCall(_ n: Int, _ a: [UInt64], _ s: RouteSocket, _ file: DarwinOpenFile, _ call: inout CallText,
                         _ mem: any KernelGuestMemory) throws -> BSDResult {
        func int(_ i: Int) -> Int32 { Int32(truncatingIfNeeded: a[i]) }
        switch n {
        case DescriptorBSD.sendto:
            guard a[2] <= 65536 else { throw fail(Code.EMSGSIZE) }
            let bytes = a[2] == 0 ? [] : try mem.read(va: a[1], count: Int(a[2]))
            return .value(UInt64(try routeWrite(s, bytes)))
        case DescriptorBSD.sendmsg:
            let h = try mem.read(va: a[1], count: 48)
            let iov = try readIOVec(h.readLE(UInt64.self, at: 16), count: h.readLE(Int32.self, at: 24), mem, limitError: Code.EMSGSIZE)
            return .value(UInt64(try routeWrite(s, try gather(iov, mem))))
        case DescriptorBSD.recvfrom:
            let m = try routeRead(s, file, flags: int(3))
            let n = min(m.count, Int(a[2]))
            if n > 0 { try mem.write(va: a[1], bytes: Array(m.prefix(n))) }
            if a[4] != 0 { try copyOutAddress([2, UInt8(InetABI.afRoute)], to: a[4], lengthPointer: a[5], mem) }
            return .value(UInt64(n))
        case DescriptorBSD.recvmsg:
            let h = try mem.read(va: a[1], count: 48)
            let iov = try readIOVec(h.readLE(UInt64.self, at: 16), count: h.readLE(Int32.self, at: 24), mem, limitError: Code.EMSGSIZE)
            let m = try routeRead(s, file, flags: int(2))
            let total = iov.reduce(0) { $0 + Int($1.length) }
            try scatter(Array(m.prefix(total)), into: iov, mem)
            try writeU32(a[1] + 8, 0, mem)
            try writeU32(a[1] + 40, 0, mem)
            try writeU32(a[1] + 44, UInt32(bitPattern: m.count > total ? InetABI.msgTrunc : 0), mem)
            return .value(UInt64(min(m.count, total)))
        case DescriptorBSD.shutdown:
            let how = int(1)
            guard (0...2).contains(how) else { throw fail(Code.EINVAL) }
            if how != 1 { s.shutRead = true }
            if how != 0 { s.shutWrite = true }
            s.signals.fire()
            return .value(0)
        case DescriptorBSD.setsockopt:
            let size = Int(UInt32(truncatingIfNeeded: a[4]))
            s.options[int(2)] = a[3] == 0 || size == 0 ? [] : try mem.read(va: a[3], count: min(size, 256))
            return .value(0)
        case DescriptorBSD.getsockopt:
            guard a[4] != 0 else { throw fail(Code.EFAULT) }
            var value: [UInt8] = []
            if int(1) == InetABI.solSocket, int(2) == InetABI.soType {
                value.appendLE(Int32(InetABI.sockRaw))
            } else {
                value = s.options[int(2)] ?? [0, 0, 0, 0]
            }
            let room = Int(try mem.read(va: a[4], count: 4).readLE(UInt32.self, at: 0))
            let n = min(room, value.count)
            if a[3] != 0, n > 0 { try mem.write(va: a[3], bytes: Array(value.prefix(n))) }
            try writeU32(a[4], UInt32(n), mem)
            return .value(0)
        case DescriptorBSD.getsockname:
            try copyOutAddress([2, UInt8(InetABI.afRoute)], to: a[1], lengthPointer: a[2], mem)
            return .value(0)
        case DescriptorBSD.getpeername, DescriptorBSD.connect, DescriptorBSD.bind:
            throw fail(Code.EOPNOTSUPP)
        default:
            throw fail(Code.EOPNOTSUPP)
        }
    }

    func routeWrite(_ s: RouteSocket, _ bytes: [UInt8]) throws -> Int {
        if s.shutWrite { throw fail(Code.EPIPE) }
        let e = s.write(bytes, pid: pid)
        if e != 0 { throw fail(e) }
        return bytes.count
    }

    func routeRead(_ s: RouteSocket, _ file: DarwinOpenFile, flags: Int32) throws -> [UInt8] {
        while true {
            if flags & InetABI.msgPeek != 0, let m = s.queue.first { return m }
            if let m = s.takeMessage() { return m }
            if s.shutRead { return [] }
            if file.isNonBlocking || flags & InetABI.msgDontWait != 0 { throw fail(Code.EAGAIN) }
            _ = try waitOnObject(s.signals, deadline: nil)
        }
    }
}
