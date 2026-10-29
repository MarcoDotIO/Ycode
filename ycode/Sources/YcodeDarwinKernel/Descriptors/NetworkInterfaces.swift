import Foundation
import YcodeDarwinABI
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

// The network interfaces the guest sees (`specs/simulator/networking-ycode.md`
// §3). Two interfaces, mirrored from the host:
//
// - `lo0` (guest index 1): the host's loopback interface and its addresses.
// - `en0` (guest index 2): the host's primary interface (the one of its
//   IPv4 default route, else the first running non-loopback interface with
//   an address), with that interface's IPv4 and IPv6 addresses, MTU, and a
//   locally administered link-layer address derived from the host's (the
//   host's own is not shown). Its default gateways are the host's.
//
// Other host interfaces (bridges, VPNs, containers) are not shown. A guest
// interface index maps to the host index of the interface it mirrors (for
// IP_BOUND_IF, scope ids, packet info). The model is read from the host at
// most every five seconds.
//
// The routing sysctls (`NET_RT_IFLIST`, `NET_RT_IFLIST2`, `NET_RT_DUMP`,
// `NET_RT_DUMP2`, `NET_RT_FLAGS`) and the interface ioctls (`SIOCGIF*`) are
// answered from this model in the Darwin layouts of the public
// `net/if.h`, `net/route.h`, `net/if_dl.h` and `netinet6/in6_var.h`.

struct GuestInterface: Equatable {
    struct IPv4: Equatable {
        var address: [UInt8]
        var netmask: [UInt8]
        var broadcast: [UInt8]?
    }

    struct IPv6: Equatable {
        var address: [UInt8]
        var prefixLength: Int
    }

    var name: String
    var index: UInt32
    var hostIndex: UInt32
    var hostName: String
    /// Darwin `IFF_*`.
    var flags: Int32
    var mtu: UInt32
    /// `IFT_ETHER` or `IFT_LOOP`.
    var type: UInt8
    var linkAddress: [UInt8]
    var ipv4: [IPv4] = []
    var ipv6: [IPv6] = []
    var gateway4: [UInt8]?
    var gateway6: [UInt8]?

    var isLoopback: Bool { type == NetworkInterfaces.iftLoop }
}

enum NetworkInterfaces {
    static let iftEther: UInt8 = 6, iftLoop: UInt8 = 0x18
    static let iffUp: Int32 = 0x1, iffBroadcast: Int32 = 0x2, iffLoopback: Int32 = 0x8, iffSmart: Int32 = 0x20,
               iffRunning: Int32 = 0x40, iffSimplex: Int32 = 0x800, iffMulticast: Int32 = 0x8000
    static let loopbackIndex: UInt32 = 1, primaryIndex: UInt32 = 2

    private static let mutex = NSLock()
    nonisolated(unsafe) private static var cached: [GuestInterface]?
    nonisolated(unsafe) private static var cachedAt: UInt64 = 0
    /// Tests replace the model.
    nonisolated(unsafe) static var override: [GuestInterface]?

    /// The guest's interfaces now (lo0, then en0 when the host has one).
    static var current: [GuestInterface] {
        mutex.lock()
        defer { mutex.unlock() }
        if let override { return override }
        let now = KernelClock.now()
        if let cached, now &- cachedAt < 5_000_000_000 { return cached }
        let fresh = readHost()
        cached = fresh
        cachedAt = now
        return fresh
    }

    /// Whether the guest can reach the world over IPv4 / IPv6: en0 has an
    /// address of the family (a global one for IPv6) and a default router.
    /// mDNSResponder's SuppressUnusable answers follow these.
    static var hasRoutableIPv4: Bool { current.contains { !$0.isLoopback && !$0.ipv4.isEmpty && $0.gateway4 != nil } }
    static var hasRoutableIPv6: Bool {
        current.contains { !$0.isLoopback && $0.gateway6 != nil && $0.ipv6.contains { !isLinkLocal($0.address) } }
    }

    static func interface(index: UInt32) -> GuestInterface? { current.first { $0.index == index } }
    static func interface(named name: String) -> GuestInterface? { current.first { $0.name == name } }

    /// Guest interface index → host index (0 stays 0; an unknown index is
    /// passed through unchanged).
    static func hostIndex(_ guest: UInt32) -> UInt32 {
        guard guest != 0 else { return 0 }
        return interface(index: guest)?.hostIndex ?? guest
    }

    /// Host interface index → guest index (0 for an interface not shown).
    static func guestIndex(_ host: UInt32) -> UInt32 {
        guard host != 0 else { return 0 }
        return current.first { $0.hostIndex == host }?.index ?? 0
    }

    // MARK: Reading the host

    private static func readHost() -> [GuestInterface] {
        struct HostIF {
            var name: String
            var index: UInt32
            var flags: UInt32
            var v4: [GuestInterface.IPv4] = []
            var v6: [GuestInterface.IPv6] = []
        }
        var hosts: [String: HostIF] = [:]
        var order: [String] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&list) == 0 {
            var p = list
            while let ifa = p {
                let name = String(cString: ifa.pointee.ifa_name)
                if hosts[name] == nil {
                    hosts[name] = HostIF(name: name, index: if_nametoindex(ifa.pointee.ifa_name), flags: ifa.pointee.ifa_flags)
                    order.append(name)
                }
                if let sa = ifa.pointee.ifa_addr {
                    let family = Int32(sa.pointee.sa_family)
                    if family == AF_INET {
                        let a = bytes(of: sa, offset: 4, count: 4)
                        let m = ifa.pointee.ifa_netmask.map { bytes(of: $0, offset: 4, count: 4) } ?? [255, 0, 0, 0]
                        var b: [UInt8]?
                        #if canImport(Glibc)
                        if ifa.pointee.ifa_flags & 0x2 != 0, let d = ifa.pointee.ifa_ifu.ifu_broadaddr {
                            b = bytes(of: d, offset: 4, count: 4)
                        }
                        #else
                        if ifa.pointee.ifa_flags & 0x2 != 0, let d = ifa.pointee.ifa_dstaddr {
                            b = bytes(of: d, offset: 4, count: 4)
                        }
                        #endif
                        hosts[name]?.v4.append(GuestInterface.IPv4(address: a, netmask: m, broadcast: b))
                    } else if family == AF_INET6 {
                        let a = bytes(of: sa, offset: 8, count: 16)
                        let m = ifa.pointee.ifa_netmask.map { bytes(of: $0, offset: 8, count: 16) } ?? []
                        let prefix = m.reduce(0) { $0 + $1.nonzeroBitCount }
                        hosts[name]?.v6.append(GuestInterface.IPv6(address: a, prefixLength: prefix))
                    }
                }
                p = ifa.pointee.ifa_next
            }
            freeifaddrs(list)
        }
        // IFF_LOOPBACK, IFF_UP | IFF_RUNNING (the same values on Linux and Darwin).
        let loopFlag: UInt32 = 0x8, upRunning: UInt32 = 0x41
        let loop = order.compactMap { hosts[$0] }.first { $0.flags & loopFlag != 0 }
        let routes = defaultRoutes()
        var primary: HostIF?
        if let r = routes.v4Interface, let h = hosts[r], h.flags & loopFlag == 0 { primary = h }
        if primary == nil {
            primary = order.compactMap { hosts[$0] }.first {
                $0.flags & loopFlag == 0 && $0.flags & upRunning == upRunning && !$0.v4.isEmpty
            }
        }
        var out: [GuestInterface] = []
        out.append(GuestInterface(
            name: "lo0", index: loopbackIndex, hostIndex: loop?.index ?? 1, hostName: loop?.name ?? "lo",
            flags: iffUp | iffLoopback | iffRunning | iffMulticast, mtu: 16384, type: iftLoop, linkAddress: [],
            ipv4: loop?.v4.isEmpty == false ? loop!.v4.map { GuestInterface.IPv4(address: $0.address, netmask: $0.netmask, broadcast: nil) }
                : [GuestInterface.IPv4(address: [127, 0, 0, 1], netmask: [255, 0, 0, 0], broadcast: nil)],
            ipv6: [GuestInterface.IPv6(address: [UInt8](repeating: 0, count: 15) + [1], prefixLength: 128),
                   GuestInterface.IPv6(address: [0xFE, 0x80] + [UInt8](repeating: 0, count: 13) + [1], prefixLength: 64)]))
        if let p = primary {
            out.append(GuestInterface(
                name: "en0", index: primaryIndex, hostIndex: p.index, hostName: p.name,
                flags: iffUp | iffBroadcast | iffSmart | iffRunning | iffSimplex | iffMulticast,
                mtu: hostMTU(p.name) ?? 1500, type: iftEther, linkAddress: guestLinkAddress(hostName: p.name),
                ipv4: p.v4, ipv6: p.v6,
                gateway4: routes.v4Interface == p.name ? routes.v4Gateway : nil,
                gateway6: routes.v6Interface == p.name ? routes.v6Gateway : nil))
        }
        return out
    }

    private static func bytes(of sa: UnsafeMutablePointer<sockaddr>, offset: Int, count: Int) -> [UInt8] {
        let raw = UnsafeRawPointer(sa)
        return (0..<count).map { raw.load(fromByteOffset: offset + $0, as: UInt8.self) }
    }

    /// The host's default routes: interface names and gateways (Linux:
    /// `/proc/net/route`, `/proc/net/ipv6_route`).
    private static func defaultRoutes() -> (v4Interface: String?, v4Gateway: [UInt8]?, v6Interface: String?, v6Gateway: [UInt8]?) {
        var v4: (String, [UInt8], UInt32)?
        if let text = try? String(contentsOfFile: "/proc/net/route", encoding: .utf8) {
            for line in text.split(separator: "\n").dropFirst() {
                let f = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
                guard f.count >= 8, f[1] == "00000000", f[7] == "00000000",
                      let gw = UInt32(f[2], radix: 16), let metric = UInt32(f[6]) else { continue }
                let g = [UInt8(gw & 0xFF), UInt8((gw >> 8) & 0xFF), UInt8((gw >> 16) & 0xFF), UInt8(gw >> 24)]
                if v4 == nil || metric < v4!.2 { v4 = (String(f[0]), g, metric) }
            }
        }
        var v6: (String, [UInt8], UInt32)?
        if let text = try? String(contentsOfFile: "/proc/net/ipv6_route", encoding: .utf8) {
            for line in text.split(separator: "\n") {
                let f = line.split(separator: " ", omittingEmptySubsequences: true)
                guard f.count >= 10, f[0] == String(repeating: "0", count: 32), f[1] == "00",
                      f[4] != String(repeating: "0", count: 32), let metric = UInt32(f[5], radix: 16) else { continue }
                let hex = Array(f[4])
                let g = stride(from: 0, to: 32, by: 2).map { UInt8(String(hex[$0..<($0 + 2)]), radix: 16) ?? 0 }
                if v6 == nil || metric < v6!.2 { v6 = (String(f[9]), g, metric) }
            }
        }
        return (v4?.0, v4?.1, v6?.0, v6?.1)
    }

    private static func hostMTU(_ name: String) -> UInt32? {
        guard let s = try? String(contentsOfFile: "/sys/class/net/\(name)/mtu", encoding: .utf8) else { return nil }
        return UInt32(s.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// A locally administered unicast link address derived from the host
    /// interface's (FNV-1a of its text), so the host's own is not exposed.
    static func guestLinkAddress(hostName: String) -> [UInt8] {
        let text = (try? String(contentsOfFile: "/sys/class/net/\(hostName)/address", encoding: .utf8)) ?? hostName
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in text.utf8 { h = (h ^ UInt64(b)) &* 0x100_0000_01b3 }
        return [0x02] + (0..<5).map { UInt8(truncatingIfNeeded: h >> (8 * UInt64($0))) }
    }

    // MARK: Darwin structures

    /// `struct sockaddr_dl` (at least 20 bytes).
    static func sockaddrDL(index: UInt32, name: String, type: UInt8, address: [UInt8]) -> [UInt8] {
        let nameBytes = Array(name.utf8)
        let length = max(20, 8 + nameBytes.count + address.count)
        var b: [UInt8] = [UInt8(length), UInt8(InetABI.afLink)]
        b.appendLE(UInt16(index))
        b += [type, UInt8(nameBytes.count), UInt8(address.count), 0]
        b += nameBytes + address
        while b.count < length { b.append(0) }
        return b
    }

    static func sockaddrIn(_ a: [UInt8]) -> [UInt8] {
        InetAddress(family: InetABI.afInet, port: 0, address: a).darwinBytes
    }

    static func sockaddrIn6(_ a: [UInt8], scope: UInt32 = 0) -> [UInt8] {
        InetAddress(family: InetABI.afInet6, port: 0, address: a, scope: scope).darwinBytes
    }

    static func ipv6Mask(_ prefix: Int) -> [UInt8] {
        (0..<16).map { i in
            let bits = max(0, min(8, prefix - 8 * i))
            return bits == 0 ? 0 : UInt8(truncatingIfNeeded: 0xFF << (8 - bits))
        }
    }

    static func isLinkLocal(_ a: [UInt8]) -> Bool { a.count == 16 && a[0] == 0xFE && a[1] & 0xC0 == 0x80 }

    /// The KAME form of a scoped address in the kernel's tables: the
    /// interface index in bytes 2–3 is not used; scope ids are separate.
    private static func appendRounded(_ sa: [UInt8], to b: inout [UInt8]) {
        b += sa
        while b.count % 4 != 0 { b.append(0) }
    }

    private static func interfaceData(_ i: GuestInterface, wide: Bool) -> [UInt8] {
        var d: [UInt8] = [i.type, 0, 0, UInt8(i.linkAddress.count), i.isLoopback ? 0 : 14, 0, 0, 0]
        d.appendLE(i.mtu)
        d.appendLE(UInt32(0))  // metric
        if wide {
            d.appendLE(UInt64(i.isLoopback ? 0 : 1_000_000_000))  // baudrate
            d += [UInt8](repeating: 0, count: 88)                  // 11 counters
            d += [UInt8](repeating: 0, count: 16)                  // timings, lastchange
        } else {
            d.appendLE(UInt32(i.isLoopback ? 0 : 1_000_000_000))
            d += [UInt8](repeating: 0, count: 44)                  // 11 counters
            d += [UInt8](repeating: 0, count: 32)                  // timings, lastchange, unused, hwassist, reserved
        }
        return d
    }

    /// `sysctl {CTL_NET, PF_ROUTE, 0, af, NET_RT_IFLIST(2), ifindex}`.
    static func interfaceList(family: Int32, index: UInt32, version2: Bool) -> [UInt8] {
        var out: [UInt8] = []
        for i in current where index == 0 || i.index == index {
            // RTM_IFINFO(2) + the link-level address.
            var m: [UInt8] = []
            let header = version2 ? 160 : 112
            m.appendLE(UInt16(0))
            m += [5, version2 ? 0x12 : 0x0E]
            m.appendLE(Int32(0x10))  // RTA_IFP
            m.appendLE(i.flags)
            m.appendLE(UInt16(i.index))
            m += [0, 0]
            if version2 {
                m.appendLE(Int32(0)); m.appendLE(Int32(256)); m.appendLE(Int32(0)); m.appendLE(Int32(0))
            }
            m += interfaceData(i, wide: version2)
            precondition(m.count == header)
            appendRounded(sockaddrDL(index: i.index, name: i.name, type: i.type, address: i.linkAddress), to: &m)
            m.putLE(UInt16(m.count), at: 0)
            out += m
            // RTM_NEWADDR per address.
            func address(_ addrs: Int32, _ sockaddrs: [[UInt8]]) {
                var a: [UInt8] = []
                a.appendLE(UInt16(0))
                a += [5, 0x0C]
                a.appendLE(addrs)
                a.appendLE(i.flags)
                a.appendLE(UInt16(i.index))
                a += [0, 0]
                a.appendLE(Int32(0))
                for s in sockaddrs { appendRounded(s, to: &a) }
                a.putLE(UInt16(a.count), at: 0)
                out += a
            }
            if family == 0 || family == InetABI.afInet {
                for v in i.ipv4 {
                    if let b = v.broadcast {
                        address(0x4 | 0x20 | 0x80, [sockaddrIn(v.netmask), sockaddrIn(v.address), sockaddrIn(b)])
                    } else {
                        address(0x4 | 0x20, [sockaddrIn(v.netmask), sockaddrIn(v.address)])
                    }
                }
            }
            if family == 0 || family == InetABI.afInet6 {
                for v in i.ipv6 {
                    let scope = isLinkLocal(v.address) ? i.index : 0
                    address(0x4 | 0x20, [sockaddrIn6(ipv6Mask(v.prefixLength)), sockaddrIn6(v.address, scope: scope)])
                }
            }
        }
        return out
    }

    struct Route {
        var destination: [UInt8]
        var gateway: [UInt8]?
        var netmask: [UInt8]?
        var index: UInt32
        var flags: Int32
    }

    /// The guest's routing table.
    static func routes(family: Int32) -> [(family: Int32, route: Route)] {
        var out: [(Int32, Route)] = []
        let up: Int32 = 0x1, gatewayFlag: Int32 = 0x2, host: Int32 = 0x4, statik: Int32 = 0x800, cloning: Int32 = 0x100
        // A default route: UP, GATEWAY, STATIC, PRCLONING, GLOBAL (networking.md §3.6).
        let defaultFlags: Int32 = up | gatewayFlag | statik | 0x10000 | 0x4000_0000
        for i in current {
            if family == 0 || family == InetABI.afInet {
                if i.isLoopback {
                    out.append((InetABI.afInet, Route(destination: [127, 0, 0, 0], netmask: [255, 0, 0, 0], index: i.index,
                                                      flags: up | statik)))
                    out.append((InetABI.afInet, Route(destination: [127, 0, 0, 1], index: i.index, flags: up | host)))
                } else {
                    if let g = i.gateway4 {
                        out.append((InetABI.afInet, Route(destination: [0, 0, 0, 0], gateway: g, netmask: [0, 0, 0, 0],
                                                          index: i.index, flags: defaultFlags)))
                    }
                    for v in i.ipv4 {
                        let net = zip(v.address, v.netmask).map { $0 & $1 }
                        out.append((InetABI.afInet, Route(destination: net, netmask: v.netmask, index: i.index, flags: up | cloning)))
                    }
                }
            }
            if family == 0 || family == InetABI.afInet6 {
                if i.isLoopback {
                    out.append((InetABI.afInet6, Route(destination: [UInt8](repeating: 0, count: 15) + [1], index: i.index,
                                                       flags: up | host)))
                } else {
                    if let g = i.gateway6 {
                        out.append((InetABI.afInet6, Route(destination: [UInt8](repeating: 0, count: 16), gateway: g,
                                                           netmask: [UInt8](repeating: 0, count: 16), index: i.index,
                                                           flags: defaultFlags)))
                    }
                    for v in i.ipv6 {
                        let mask = ipv6Mask(v.prefixLength)
                        out.append((InetABI.afInet6, Route(destination: zip(v.address, mask).map { $0 & $1 }, netmask: mask,
                                                           index: i.index, flags: up | cloning)))
                    }
                }
            }
        }
        return out
    }

    /// `sysctl {CTL_NET, PF_ROUTE, 0, af, NET_RT_DUMP | NET_RT_DUMP2 | NET_RT_FLAGS, flags}`.
    static func routeDump(family: Int32, version2: Bool, requiredFlags: Int32) -> [UInt8] {
        var out: [UInt8] = []
        var seq: Int32 = 0
        for (fam, r) in routes(family: family) where requiredFlags == 0 || r.flags & requiredFlags == requiredFlags {
            var m: [UInt8] = []
            var addrs: Int32 = 0x1 | 0x2
            if r.netmask != nil { addrs |= 0x4 }
            m.appendLE(UInt16(0))
            m += [5, version2 ? 0x14 : 0x04]
            m.appendLE(UInt16(r.index))
            m += [0, 0]
            m.appendLE(r.flags)
            m.appendLE(addrs)
            m.appendLE(Int32(0))       // pid / refcnt
            seq += 1
            m.appendLE(version2 ? Int32(0) : seq)  // seq / parentflags
            m.appendLE(Int32(0))       // errno / reserved
            m.appendLE(Int32(0))       // use
            m.appendLE(UInt32(0))      // inits
            var rmx = [UInt8](repeating: 0, count: 56)
            rmx.putLE(UInt32(interface(index: r.index)?.mtu ?? 1500), at: 4)
            m += rmx
            let sa: ([UInt8]) -> [UInt8] = fam == InetABI.afInet ? { sockaddrIn($0) } : { sockaddrIn6($0) }
            appendRounded(sa(r.destination), to: &m)
            if let g = r.gateway {
                appendRounded(sa(g), to: &m)
            } else {
                let i = interface(index: r.index)
                appendRounded(sockaddrDL(index: r.index, name: i?.name ?? "", type: i?.type ?? 0, address: i?.linkAddress ?? []),
                              to: &m)
            }
            if let mask = r.netmask { appendRounded(sa(mask), to: &m) }
            m.putLE(UInt16(m.count), at: 0)
            out += m
        }
        return out
    }

    /// The routing sysctl for MIB `{4, 17, ...}`; nil for a name this
    /// layer does not serve (ENOENT for the caller).
    static func routingSysctl(_ mib: [Int32]) -> [UInt8]? {
        guard mib.count >= 5, mib[0] == 4, mib[1] == 17 else { return nil }
        let family = mib[3]
        let arg = mib.count >= 6 ? mib[5] : 0
        switch mib[4] {
        case 1: return routeDump(family: family, version2: false, requiredFlags: 0)
        case 2: return routeDump(family: family, version2: false, requiredFlags: arg)
        case 3: return interfaceList(family: family, index: UInt32(bitPattern: arg), version2: false)
        case 6: return interfaceList(family: family, index: UInt32(bitPattern: arg), version2: true)
        case 7: return routeDump(family: family, version2: true, requiredFlags: 0)
        default: return nil
        }
    }

    // MARK: Interface ioctls

    /// An `ioctl` of group 'i' on a socket: the bytes to write back at the
    /// argument (the same size as `request`'s parameter), or an errno. For
    /// SIOCGIFCONF the caller passes the guest buffer through `conf`.
    enum IoctlResult: Equatable {
        case reply([UInt8])
        case failure(Int32)
        /// SIOCGIFCONF: the entries to copy to the guest buffer (each the
        /// name and an address: 32 bytes, or 16 + sa_len when longer).
        case configuration([[UInt8]])
        case notMine
    }

    static let siocGIfConf: UInt32 = 0xC00C_6924

    static func ioctl(_ request: UInt32, argument: [UInt8]) -> IoctlResult {
        if request == siocGIfConf {
            var b: [[UInt8]] = []
            for i in current {
                func entry(_ sa: [UInt8]) {
                    var e = [UInt8](repeating: 0, count: 16)
                    let n = Array(i.name.utf8.prefix(15))
                    e.replaceSubrange(0..<n.count, with: n)
                    e += sa
                    while e.count < 32 { e.append(0) }
                    b.append(e)
                }
                entry(sockaddrDL(index: i.index, name: i.name, type: i.type, address: i.linkAddress))
                for v in i.ipv4 { entry(sockaddrIn(v.address)) }
                for v in i.ipv6 { entry(sockaddrIn6(v.address, scope: isLinkLocal(v.address) ? i.index : 0)) }
            }
            return .configuration(b)
        }
        guard (request >> 8) & 0xFF == 0x69 else { return .notMine }
        let name = String(decoding: argument.prefix(16).prefix { $0 != 0 }, as: UTF8.self)
        guard let i = interface(named: name) else { return .failure(DarwinErrnoCode.ENXIO) }
        var out = argument
        func put(_ bytes: [UInt8]) {
            let room = out.count - 16
            out.replaceSubrange(16..<(16 + min(room, bytes.count)), with: bytes.prefix(room))
        }
        func int32(_ v: Int32) { var b: [UInt8] = []; b.appendLE(v); put(b) }
        switch request {
        case 0xC020_6911:  // SIOCGIFFLAGS
            var b: [UInt8] = []
            b.appendLE(Int16(truncatingIfNeeded: i.flags))
            put(b)
        case 0xC020_6921, 0xC020_6925, 0xC020_6923, 0xC020_6922:  // SIOCGIF{ADDR,NETMASK,BRDADDR,DSTADDR}
            guard let v = i.ipv4.first else { return .failure(49) }  // EADDRNOTAVAIL
            switch request {
            case 0xC020_6921: put(sockaddrIn(v.address))
            case 0xC020_6925: put(sockaddrIn(v.netmask))
            case 0xC020_6923:
                guard let b = v.broadcast else { return .failure(DarwinErrnoCode.EINVAL) }
                put(sockaddrIn(b))
            default:
                return .failure(DarwinErrnoCode.EINVAL)
            }
        case 0xC020_6933, 0xC020_6948: int32(Int32(i.mtu))                     // SIOCGIFMTU, SIOCGIFALTMTU
        case 0xC020_6917, 0xC020_6935: int32(0)                                // SIOCGIFMETRIC, SIOCGIFPHYS
        case 0xC020_6944:                                                      // SIOCGIFDEVMTU
            var b: [UInt8] = []
            b.appendLE(Int32(i.mtu)); b.appendLE(Int32(72)); b.appendLE(Int32(i.isLoopback ? 16384 : 9000))
            put(b)
        case 0xC020_69AD:                                                      // SIOCGIFFUNCTIONALTYPE
            int32(i.isLoopback ? 1 : 2)  // IFRTYPE_FUNCTIONAL_LOOPBACK / _WIRED
        case 0xC020_698E, 0xC020_695B:                                         // SIOCGIFEFLAGS, SIOCGIFCAP
            put([UInt8](repeating: 0, count: 8))
        case 0xC020_698A:                                                      // SIOCGIFLINKQUALITYMETRIC
            int32(i.isLoopback ? -2 : 100)  // IFNET_LQM_THRESH_OFF / _GOOD
        case 0xC020_699D, 0xC020_69A0, 0xC020_69CC, 0xC020_69DA, 0xC020_69CE, 0xC020_698C, 0xC020_69C0,
             0xC020_69BA, 0xC020_69C7, 0xC020_69D8:
            // SIOCGIFDELEGATE, SIOCGIFEXPENSIVE, SIOCGIFCONSTRAINED,
            // SIOCGIFULTRACONSTRAINED, SIOCGIFXFLAGS, SIOCGIFOPPORTUNISTIC,
            // SIOCGIFLOWINTERNET, SIOCGIFTIMESTAMPENABLED, SIOCGIFLOWPOWER,
            // SIOCGIFNOTRAFFICSHAPING (xnu sockio_private.h): none, off.
            put([UInt8](repeating: 0, count: 8))
        case 0xC02C_6938, 0xC02C_6948:                                         // SIOCGIF(X)MEDIA
            guard !i.isLoopback else { return .failure(DarwinErrnoCode.EOPNOTSUPP) }
            var b: [UInt8] = []
            b.appendLE(Int32(0x20)); b.appendLE(Int32(0)); b.appendLE(Int32(3)); b.appendLE(Int32(0x20)); b.appendLE(Int32(0))
            put(b)
        case 0xC120_6921, 0xC120_6925, 0xC120_6949, 0xC120_6951:              // in6_ifreq requests
            let asked = argument.count >= 16 + 28 ? Array(argument[(16 + 8)..<(16 + 24)]) : []
            guard let v = i.ipv6.first(where: { $0.address == asked }) ?? (request == 0xC120_6921 ? i.ipv6.first : nil) else {
                return .failure(49)
            }
            switch request {
            case 0xC120_6921: put(sockaddrIn6(v.address, scope: isLinkLocal(v.address) ? i.index : 0))
            case 0xC120_6925: put(sockaddrIn6(ipv6Mask(v.prefixLength)))
            case 0xC120_6949: put([UInt8](repeating: 0, count: 4))             // SIOCGIFAFLAG_IN6: no flags
            default:                                                            // SIOCGIFALIFETIME_IN6: infinite
                var b = [UInt8](repeating: 0, count: 16)
                b.appendLE(UInt32.max); b.appendLE(UInt32.max)
                put(b)
            }
        default:
            return .failure(DarwinErrnoCode.EOPNOTSUPP)
        }
        return .reply(out)
    }
}

/// The guest's network for host services (the SCDynamicStore host service
/// publishes it as SystemConfiguration state; networking-ycode.md §5).
public enum GuestNetwork {
    public struct Interface: Sendable {
        public let name: String
        public let isLoopback: Bool
        public let mtu: Int
        public let ipv4: [IPv4]
        public let ipv6: [IPv6]
        /// The default gateways through this interface (text form).
        public let router4: String?
        public let router6: String?
    }

    public struct IPv4: Sendable {
        public let address: String
        public let netmask: String
        public let broadcast: String?
    }

    public struct IPv6: Sendable {
        public let address: String
        public let prefixLength: Int
    }

    /// False with `YCODE_NO_NETWORK=1`.
    public static var enabled: Bool { !InetSocketPolicy.disabled }

    /// The guest's interfaces now (lo0, then en0 when the host has one), with
    /// their addresses as text.
    public static var interfaces: [Interface] {
        NetworkInterfaces.current.map { i in
            Interface(name: i.name, isLoopback: i.isLoopback, mtu: Int(i.mtu),
                      ipv4: i.ipv4.map { IPv4(address: text4($0.address), netmask: text4($0.netmask), broadcast: $0.broadcast.map(text4)) },
                      ipv6: i.ipv6.map { IPv6(address: text6($0.address), prefixLength: $0.prefixLength) },
                      router4: i.gateway4.map(text4), router6: i.gateway6.map(text6))
        }
    }

    /// The host's name servers (text form).
    public static var nameServers: [String] {
        HostResolver.nameServers().map { $0.ipv6 ? text6($0.address) : text4($0.address) }
    }

    static func text4(_ a: [UInt8]) -> String { a.map(String.init).joined(separator: ".") }

    /// RFC 5952 text of an IPv6 address (the longest run of zero groups as "::").
    static func text6(_ a: [UInt8]) -> String {
        guard a.count == 16 else { return "::" }
        let groups = (0..<8).map { UInt16(a[2 * $0]) << 8 | UInt16(a[2 * $0 + 1]) }
        var best = (start: -1, length: 0)
        var i = 0
        while i < 8 {
            guard groups[i] == 0 else { i += 1; continue }
            var j = i
            while j < 8 && groups[j] == 0 { j += 1 }
            if j - i > best.length && j - i >= 2 { best = (i, j - i) }
            i = j
        }
        func hex(_ r: Range<Int>) -> String { r.map { String(groups[$0], radix: 16) }.joined(separator: ":") }
        if best.start < 0 { return hex(0..<8) }
        return hex(0..<best.start) + "::" + hex((best.start + best.length)..<8)
    }
}
