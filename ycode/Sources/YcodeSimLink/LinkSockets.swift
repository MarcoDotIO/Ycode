// Sockets of the simulator link (sim-link.md §7): the host's TCP listener
// (any address: every connection must pass the handshake before anything
// is acted on) and UDP sockets for the media channel. TCP_NODELAY on every
// connection (input events are small; Nagle would hold them).

import Foundation
import YcodeDisplayStream
#if canImport(Glibc)
import Glibc
#endif

public enum LinkSockets {
    static var streamType: Int32 {
        #if canImport(Glibc)
        Int32(SOCK_STREAM.rawValue)
        #else
        SOCK_STREAM
        #endif
    }

    static var datagramType: Int32 {
        #if canImport(Glibc)
        Int32(SOCK_DGRAM.rawValue)
        #else
        SOCK_DGRAM
        #endif
    }

    static func closeFD(_ fd: Int32) {
        #if canImport(Glibc)
        _ = Glibc.close(fd)
        #else
        _ = Darwin.close(fd)
        #endif
    }

    /// Receive and send timeouts (0: none).
    public static func setTimeouts(_ fd: Int32, seconds: TimeInterval) {
        var tv = timeval(tv_sec: Int(seconds), tv_usec: numericCast(Int((seconds - Double(Int(seconds))) * 1e6)))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    /// The host's sockets stay out of the devices it starts: a launcher that
    /// inherited the listening port kept it bound after the service stopped.
    public static func closeOnExec(_ fd: Int32) {
        _ = fcntl(fd, F_SETFD, fcntl(fd, F_GETFD) | FD_CLOEXEC)
    }

    public static func noDelay(_ fd: Int32) {
        var one: Int32 = 1
        setsockopt(fd, Int32(IPPROTO_TCP), TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
    }

    /// An IPv4 socket address.
    public static func ipv4(_ host: String, _ port: Int) -> sockaddr_in? {
        var a = sockaddr_in()
        a.sin_family = sa_family_t(AF_INET)
        a.sin_port = in_port_t(UInt16(port).bigEndian)
        if host.isEmpty || host == "0.0.0.0" || host == "*" {
            a.sin_addr.s_addr = 0
        } else if inet_pton(AF_INET, host, &a.sin_addr) != 1 {
            var hints = addrinfo()
            hints.ai_family = AF_INET
            var list: UnsafeMutablePointer<addrinfo>?
            guard getaddrinfo(host, nil, &hints, &list) == 0, let first = list else { return nil }
            defer { freeaddrinfo(list) }
            a.sin_addr = first.pointee.ai_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
        }
        return a
    }

    public static func describe(_ a: sockaddr_in) -> String {
        var buf = [CChar](repeating: 0, count: 64)
        var addr = a.sin_addr
        inet_ntop(AF_INET, &addr, &buf, 64)
        return String(cString: buf) + ":" + String(UInt16(bigEndian: a.sin_port))
    }
}

/// The host's TCP listener.
public final class LinkListener: @unchecked Sendable {
    public let fd: Int32
    public let port: Int

    public init(host: String, port: Int) throws {
        guard var addr = LinkSockets.ipv4(host, port) else { throw DisplaySocketError(message: "cannot resolve \(host)") }
        let fd = socket(AF_INET, LinkSockets.streamType, 0)
        guard fd >= 0 else { throw DisplaySocketError("socket") }
        LinkSockets.closeOnExec(fd)
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        let r = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard r == 0, listen(fd, 16) == 0 else {
            let e = DisplaySocketError("bind \(host):\(port)")
            LinkSockets.closeFD(fd)
            throw e
        }
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        var bound = sockaddr_in()
        _ = withUnsafeMutablePointer(to: &bound) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        self.fd = fd
        self.port = Int(UInt16(bigEndian: bound.sin_port))
    }

    /// The next connection and its peer's address; nil once closed.
    public func accept() -> (DisplayConnection, sockaddr_in)? {
        while true {
            var peer = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let c = withUnsafeMutablePointer(to: &peer) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                #if canImport(Glibc)
                Glibc.accept(fd, $0, &len)
                #else
                Darwin.accept(fd, $0, &len)
                #endif
            } }
            if c >= 0 {
                LinkSockets.closeOnExec(c)
                LinkSockets.noDelay(c)
                return (DisplayConnection(fd: c), peer)
            }
            if errno == EINTR || errno == ECONNABORTED { continue }
            return nil
        }
    }

    public func close() {
        _ = shutdown(fd, Int32(SHUT_RDWR))
        LinkSockets.closeFD(fd)
    }
}

/// A UDP socket (the media channel).
public final class LinkDatagramSocket: @unchecked Sendable {
    public let fd: Int32
    public let port: Int

    /// Bound to `host:port` (port 0: any free port).
    public init(host: String = "0.0.0.0", port: Int = 0, receiveBuffer: Int32 = 4 << 20, sendBuffer: Int32 = 4 << 20) throws {
        guard var addr = LinkSockets.ipv4(host, port) else { throw DisplaySocketError(message: "cannot resolve \(host)") }
        let fd = socket(AF_INET, LinkSockets.datagramType, 0)
        guard fd >= 0 else { throw DisplaySocketError("socket") }
        LinkSockets.closeOnExec(fd)
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var rb = receiveBuffer, sb = sendBuffer
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &rb, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &sb, socklen_t(MemoryLayout<Int32>.size))
        let r = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard r == 0 else {
            let e = DisplaySocketError("bind udp \(host):\(port)")
            LinkSockets.closeFD(fd)
            throw e
        }
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        var bound = sockaddr_in()
        _ = withUnsafeMutablePointer(to: &bound) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        self.fd = fd
        self.port = Int(UInt16(bigEndian: bound.sin_port))
    }

    @discardableResult
    public func send(_ bytes: [UInt8], to addr: sockaddr_in) -> Bool {
        var a = addr
        let n = bytes.withUnsafeBytes { b in
            withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                sendto(fd, b.baseAddress, b.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            } }
        }
        return n == bytes.count
    }

    /// The next datagram and its sender; nil on a timeout or once closed.
    public func receive(max: Int = 2048) -> ([UInt8], sockaddr_in)? {
        var buf = [UInt8](repeating: 0, count: max)
        var peer = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        while true {
            let n = buf.withUnsafeMutableBytes { b in
                withUnsafeMutablePointer(to: &peer) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, b.baseAddress, b.count, 0, $0, &len) } }
            }
            if n >= 0 { return (Array(buf.prefix(n)), peer) }
            if errno == EINTR { continue }
            return nil
        }
    }

    public func setReceiveTimeout(_ seconds: TimeInterval) { LinkSockets.setTimeouts(fd, seconds: seconds) }

    public func close() {
        _ = shutdown(fd, Int32(SHUT_RDWR))
        LinkSockets.closeFD(fd)
    }
}
