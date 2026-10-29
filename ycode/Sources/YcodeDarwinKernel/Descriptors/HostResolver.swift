import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

// Name resolution on the host for the guest's DNS service
// (`specs/simulator/networking-ycode.md` §4). Address lookups use the
// host's `getaddrinfo` (so `/etc/hosts` and the host's resolver
// configuration apply); record queries (`DNSServiceQueryRecord`: HTTPS,
// SRV, TXT, CNAME...) use a small DNS client of Ycode's own that asks the
// host's name servers (`/etc/resolv.conf`) over UDP, and over TCP when the
// answer is truncated (RFC 1035, RFC 6891 for the EDNS(0) buffer size,
// RFC 7766 for TCP). Every call blocks; callers run it off the kernel lock.

enum HostResolver {
    struct Record: Equatable {
        var name: String
        var type: UInt16
        var rrclass: UInt16
        var ttl: UInt32
        /// Uncompressed rdata (names inside CNAME, NS, PTR, MX, SOA and SRV
        /// rdata are expanded).
        var rdata: [UInt8]
    }

    enum Outcome: Equatable {
        /// Records of the asked type (after CNAMEs, which are included first).
        case records([Record])
        /// NXDOMAIN.
        case noSuchName
        /// The name exists but has no record of that type.
        case noRecords
        /// No answer (server failure, timeout).
        case failure
    }

    static let typeA: UInt16 = 1, typeCNAME: UInt16 = 5, typeAAAA: UInt16 = 28
    /// TTL reported for getaddrinfo answers (the host call gives none).
    static let addressTTL: UInt32 = 60

    /// Tests replace the lookups.
    nonisolated(unsafe) static var addressOverride: ((String, Bool) -> [[UInt8]]?)?
    nonisolated(unsafe) static var queryOverride: ((String, UInt16, UInt16) -> Outcome)?

    /// The IPv4 (or IPv6) addresses of `name` from the host's getaddrinfo:
    /// nil when the name does not exist (or the lookup failed), an empty
    /// list when it has no address of that family.
    static func addresses(_ name: String, ipv6: Bool) -> [[UInt8]]? {
        if let addressOverride { return addressOverride(name, ipv6) }
        var hints = addrinfo()
        hints.ai_family = ipv6 ? AF_INET6 : AF_INET
        #if canImport(Glibc)
        hints.ai_socktype = Int32(SOCK_STREAM.rawValue)
        #else
        hints.ai_socktype = SOCK_STREAM
        #endif
        var result: UnsafeMutablePointer<addrinfo>?
        let r = getaddrinfo(name, nil, &hints, &result)
        guard r == 0 else {
            // A name with addresses of the other family only is "no data".
            #if canImport(Glibc)
            if r == -5 || r == -9 { return [] }  // EAI_NODATA, EAI_ADDRFAMILY (GNU)
            #endif
            if r == EAI_NONAME, let other = otherFamilyExists(name, ipv6: ipv6), other { return [] }
            return nil
        }
        defer { freeaddrinfo(result) }
        var out: [[UInt8]] = []
        var p = result
        while let ai = p {
            if let sa = ai.pointee.ai_addr {
                let raw = UnsafeRawPointer(sa)
                let bytes: [UInt8] = ipv6 ? (0..<16).map { raw.load(fromByteOffset: 8 + $0, as: UInt8.self) }
                    : (0..<4).map { raw.load(fromByteOffset: 4 + $0, as: UInt8.self) }
                if !out.contains(bytes) { out.append(bytes) }
            }
            p = ai.pointee.ai_next
        }
        return out
    }

    private static func otherFamilyExists(_ name: String, ipv6: Bool) -> Bool? {
        var hints = addrinfo()
        hints.ai_family = ipv6 ? AF_INET : AF_INET6
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(name, nil, &hints, &result) == 0 else { return false }
        freeaddrinfo(result)
        return true
    }

    // MARK: DNS client

    /// The host's name servers (`/etc/resolv.conf`), as sockaddr-ready
    /// (family, bytes) pairs.
    static func nameServers() -> [(ipv6: Bool, address: [UInt8])] {
        guard let text = try? String(contentsOfFile: "/etc/resolv.conf", encoding: .utf8) else {
            return [(false, [127, 0, 0, 1])]
        }
        var out: [(Bool, [UInt8])] = []
        for line in text.split(separator: "\n") {
            let f = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard f.count >= 2, f[0] == "nameserver" else { continue }
            let host = String(f[1].split(separator: "%").first ?? f[1])
            var v4 = in_addr()
            var v6 = in6_addr()
            if inet_pton(AF_INET, host, &v4) == 1 {
                out.append((false, withUnsafeBytes(of: &v4) { Array($0) }))
            } else if inet_pton(AF_INET6, host, &v6) == 1 {
                out.append((true, withUnsafeBytes(of: &v6) { Array($0) }))
            }
        }
        return out.isEmpty ? [(false, [127, 0, 0, 1])] : out
    }

    /// A DNS query for `name` (type, class) at the host's name servers.
    static func query(_ name: String, type: UInt16, rrclass: UInt16 = 1) -> Outcome {
        if let queryOverride { return queryOverride(name, type, rrclass) }
        let id = UInt16.random(in: 0...UInt16.max)
        guard let message = DNSMessage.query(id: id, name: name, type: type, rrclass: rrclass) else { return .failure }
        for server in nameServers() {
            for _ in 0..<2 {
                guard var reply = exchangeUDP(message, server: server) else { continue }
                if DNSMessage.isTruncated(reply), let tcp = exchangeTCP(message, server: server) { reply = tcp }
                if let outcome = DNSMessage.outcome(reply, id: id, type: type) { return outcome }
            }
        }
        return .failure
    }

    private static func address(_ server: (ipv6: Bool, address: [UInt8])) -> [UInt8] {
        InetAddress(family: server.ipv6 ? InetABI.afInet6 : InetABI.afInet, port: 53, address: server.address)
            .hostBytes(hostScope: 0)
    }

    private static func setTimeout(_ fd: Int32, seconds: Int) {
        var tv = timeval(tv_sec: seconds, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    private static func blockingSocket(_ ipv6: Bool, stream: Bool) -> Int32 {
        #if canImport(Glibc)
        let type = Int32(stream ? SOCK_STREAM.rawValue : SOCK_DGRAM.rawValue) | Int32(SOCK_CLOEXEC.rawValue)
        #else
        let type = stream ? SOCK_STREAM : SOCK_DGRAM
        #endif
        return socket(ipv6 ? AF_INET6 : AF_INET, type, 0)
    }

    private static func exchangeUDP(_ message: [UInt8], server: (ipv6: Bool, address: [UInt8])) -> [UInt8]? {
        let fd = blockingSocket(server.ipv6, stream: false)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        setTimeout(fd, seconds: 3)
        let target = address(server)
        guard HostSocketCalls.withAddress(target, { connect(fd, $0, $1) }) == 0 else { return nil }
        guard message.withUnsafeBytes({ send(fd, $0.baseAddress, $0.count, 0) }) == message.count else { return nil }
        var buffer = [UInt8](repeating: 0, count: 4096)
        let n = buffer.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
        return n > 12 ? Array(buffer.prefix(n)) : nil
    }

    private static func exchangeTCP(_ message: [UInt8], server: (ipv6: Bool, address: [UInt8])) -> [UInt8]? {
        let fd = blockingSocket(server.ipv6, stream: true)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        setTimeout(fd, seconds: 5)
        guard HostSocketCalls.withAddress(address(server), { connect(fd, $0, $1) }) == 0 else { return nil }
        let framed = [UInt8(message.count >> 8), UInt8(message.count & 0xFF)] + message
        guard framed.withUnsafeBytes({ send(fd, $0.baseAddress, $0.count, 0) }) == framed.count else { return nil }
        func readExactly(_ n: Int) -> [UInt8]? {
            var out = [UInt8](repeating: 0, count: n)
            var got = 0
            while got < n {
                let r = out.withUnsafeMutableBytes { recv(fd, $0.baseAddress! + got, n - got, 0) }
                guard r > 0 else { return nil }
                got += r
            }
            return out
        }
        guard let len = readExactly(2) else { return nil }
        return readExactly(Int(len[0]) << 8 | Int(len[1]))
    }
}

/// DNS message encoding and decoding (RFC 1035).
enum DNSMessage {
    /// The wire form of a domain name (nil for an invalid one).
    static func encodeName(_ name: String) -> [UInt8]? {
        var out: [UInt8] = []
        let trimmed = name.hasSuffix(".") ? String(name.dropLast()) : name
        if !trimmed.isEmpty {
            for label in trimmed.split(separator: ".", omittingEmptySubsequences: false) {
                let b = Array(label.utf8)
                guard !b.isEmpty, b.count <= 63 else { return nil }
                out.append(UInt8(b.count))
                out += b
            }
        }
        out.append(0)
        return out.count <= 255 ? out : nil
    }

    /// A recursive query with an EDNS(0) OPT record (1232-byte buffer).
    static func query(id: UInt16, name: String, type: UInt16, rrclass: UInt16) -> [UInt8]? {
        guard let qname = encodeName(name) else { return nil }
        var m: [UInt8] = []
        m.appendBE16(id)
        m.appendBE16(0x0100)  // RD
        m.appendBE16(1); m.appendBE16(0); m.appendBE16(0); m.appendBE16(1)
        m += qname
        m.appendBE16(type)
        m.appendBE16(rrclass)
        m += [0]              // OPT: root name
        m.appendBE16(41)
        m.appendBE16(1232)
        m.appendBE32(0)
        m.appendBE16(0)
        return m
    }

    static func isTruncated(_ m: [UInt8]) -> Bool { m.count >= 4 && m[2] & 0x02 != 0 }

    /// Reads a (possibly compressed) name at `offset`: the dotted name
    /// (with a trailing dot) and the offset after it in the message.
    static func readName(_ m: [UInt8], at offset: Int) -> (name: String, next: Int)? {
        var labels: [String] = []
        var p = offset
        var next: Int?
        var jumps = 0
        while true {
            guard p < m.count else { return nil }
            let len = Int(m[p])
            if len == 0 {
                p += 1
                break
            }
            if len & 0xC0 == 0xC0 {
                guard p + 1 < m.count, jumps < 32 else { return nil }
                if next == nil { next = p + 2 }
                p = (len & 0x3F) << 8 | Int(m[p + 1])
                jumps += 1
                continue
            }
            guard len <= 63, p + 1 + len <= m.count else { return nil }
            labels.append(String(decoding: m[(p + 1)..<(p + 1 + len)], as: UTF8.self))
            p += 1 + len
        }
        return (labels.joined(separator: ".") + ".", next ?? p)
    }

    /// rdata with its embedded names expanded (types whose rdata carries
    /// compressible names).
    static func expandRData(_ m: [UInt8], type: UInt16, at offset: Int, length: Int) -> [UInt8]? {
        func name(at o: Int) -> (bytes: [UInt8], next: Int)? {
            guard let r = readName(m, at: o), let b = encodeName(r.name) else { return nil }
            return (b, r.next)
        }
        switch type {
        case 2, 5, 12:  // NS, CNAME, PTR
            return name(at: offset)?.bytes
        case 15:        // MX
            guard length >= 3, let n = name(at: offset + 2) else { return nil }
            return Array(m[offset..<(offset + 2)]) + n.bytes
        case 33:        // SRV
            guard length >= 7, let n = name(at: offset + 6) else { return nil }
            return Array(m[offset..<(offset + 6)]) + n.bytes
        case 6:         // SOA
            guard let a = name(at: offset), let b = name(at: a.next), b.next + 20 <= m.count else { return nil }
            return a.bytes + b.bytes + Array(m[b.next..<(b.next + 20)])
        default:
            return Array(m[offset..<(offset + length)])
        }
    }

    /// The outcome of a reply to query `id` for `type`; nil when the reply
    /// is not usable (wrong id, malformed).
    static func outcome(_ m: [UInt8], id: UInt16, type: UInt16) -> HostResolver.Outcome? {
        guard m.count >= 12, m.readBE16(at: 0) == id, m[2] & 0x80 != 0 else { return nil }
        let rcode = m[3] & 0x0F
        if rcode == 3 { return .noSuchName }
        guard rcode == 0 else { return .failure }
        let qd = Int(m.readBE16(at: 4)), an = Int(m.readBE16(at: 6))
        var p = 12
        for _ in 0..<qd {
            guard let n = readName(m, at: p) else { return nil }
            p = n.next + 4
        }
        var records: [HostResolver.Record] = []
        for _ in 0..<an {
            guard let n = readName(m, at: p), n.next + 10 <= m.count else { return nil }
            let t = m.readBE16(at: n.next), c = m.readBE16(at: n.next + 2), ttl = m.readBE32(at: n.next + 4)
            let len = Int(m.readBE16(at: n.next + 8))
            let start = n.next + 10
            guard start + len <= m.count else { return nil }
            if t == type || t == HostResolver.typeCNAME, let rdata = expandRData(m, type: t, at: start, length: len) {
                records.append(HostResolver.Record(name: n.name, type: t, rrclass: c, ttl: ttl, rdata: rdata))
            }
            p = start + len
        }
        if records.contains(where: { $0.type == type }) || type == HostResolver.typeCNAME && !records.isEmpty {
            return .records(records)
        }
        return .noRecords
    }
}
