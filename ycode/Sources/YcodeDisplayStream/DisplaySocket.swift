// Blocking stream sockets for the display stream (display-stream.md §1):
// a Unix-domain socket path or a TCP host and port.

import Foundation
#if canImport(Glibc)
import Glibc
private let streamType = Int32(SOCK_STREAM.rawValue)
#elseif canImport(Darwin)
import Darwin
private let streamType = SOCK_STREAM
#endif

public enum DisplayAddress: Sendable, Equatable, CustomStringConvertible {
    case unix(String)
    case tcp(host: String, port: UInt16)

    /// "unix:/path", "/path" (or "./path"), "host:port", or "port" (127.0.0.1).
    public init?(_ text: String) {
        if text.hasPrefix("unix:") {
            let path = String(text.dropFirst(5))
            guard !path.isEmpty else { return nil }
            self = .unix(path)
        } else if text.hasPrefix("/") || text.hasPrefix("./") {
            self = .unix(text)
        } else if let port = UInt16(text) {
            self = .tcp(host: "127.0.0.1", port: port)
        } else if let colon = text.lastIndex(of: ":"), let port = UInt16(text[text.index(after: colon)...]) {
            let host = String(text[..<colon])
            self = .tcp(host: host.isEmpty ? "127.0.0.1" : host, port: port)
        } else {
            return nil
        }
    }

    public var description: String {
        switch self {
        case .unix(let p): "unix:" + p
        case .tcp(let h, let p): "\(h):\(p)"
        }
    }
}

public struct DisplaySocketError: Error, CustomStringConvertible {
    public let description: String
    init(_ what: String) { description = what + ": " + String(cString: strerror(errno)) }
    init(message: String) { description = message }
}

/// A connected stream socket (blocking).
public final class DisplayConnection: @unchecked Sendable {
    public let fd: Int32
    private let sendLock = NSLock()
    private var closed = false
    private let closeLock = NSLock()

    public init(fd: Int32) {
        self.fd = fd
        #if canImport(Darwin)
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        #endif
    }

    deinit { close() }

    /// Writes all bytes (from any thread; whole messages never interleave).
    public func send(_ bytes: [UInt8]) throws {
        try sendLock.withLock {
            var at = 0
            while at < bytes.count {
                let n = bytes.withUnsafeBytes { buf -> Int in
                    #if canImport(Glibc)
                    return Glibc.send(fd, buf.baseAddress! + at, buf.count - at, Int32(MSG_NOSIGNAL))
                    #else
                    return Darwin.send(fd, buf.baseAddress! + at, buf.count - at, Int32(MSG_NOSIGNAL))
                    #endif
                }
                if n < 0 {
                    if errno == EINTR { continue }
                    throw DisplaySocketError("send")
                }
                at += n
            }
        }
    }

    public func send(_ message: DisplayMessage) throws { try send(message.encoded()) }

    /// Reads up to `max` bytes; nil at the end of the stream or on an error.
    public func receive(max: Int = 256 << 10) -> [UInt8]? {
        var buf = [UInt8](repeating: 0, count: max)
        while true {
            let n = buf.withUnsafeMutableBytes { recv(fd, $0.baseAddress, max, 0) }
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { return nil }
            return Array(buf[0..<n])
        }
    }

    /// Shuts the socket down (a blocked receive returns) and closes it once.
    public func close() {
        closeLock.withLock {
            guard !closed else { return }
            closed = true
            _ = shutdown(fd, Int32(SHUT_RDWR))
            #if canImport(Glibc)
            _ = Glibc.close(fd)
            #else
            _ = Darwin.close(fd)
            #endif
        }
    }

    public static func connect(to address: DisplayAddress) throws -> DisplayConnection {
        switch address {
        case .unix(let path):
            let fd = socket(AF_UNIX, streamType, 0)
            guard fd >= 0 else { throw DisplaySocketError("socket") }
            var addr = try unixAddress(path)
            let r = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    #if canImport(Glibc)
                    Glibc.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                    #else
                    Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                    #endif
                }
            }
            if r != 0 {
                let e = DisplaySocketError("connect \(path)")
                _ = closeFD(fd)
                throw e
            }
            return DisplayConnection(fd: fd)
        case .tcp(let host, let port):
            var hints = addrinfo()
            hints.ai_family = AF_UNSPEC
            hints.ai_socktype = streamType
            var list: UnsafeMutablePointer<addrinfo>?
            guard getaddrinfo(host, String(port), &hints, &list) == 0, let first = list else {
                throw DisplaySocketError(message: "cannot resolve \(host)")
            }
            defer { freeaddrinfo(list) }
            var cursor: UnsafeMutablePointer<addrinfo>? = first
            var lastError = DisplaySocketError(message: "no address for \(host)")
            while let ai = cursor {
                let fd = socket(ai.pointee.ai_family, ai.pointee.ai_socktype, ai.pointee.ai_protocol)
                if fd >= 0 {
                    #if canImport(Glibc)
                    let r = Glibc.connect(fd, ai.pointee.ai_addr, ai.pointee.ai_addrlen)
                    #else
                    let r = Darwin.connect(fd, ai.pointee.ai_addr, ai.pointee.ai_addrlen)
                    #endif
                    if r == 0 {
                        var one: Int32 = 1
                        setsockopt(fd, Int32(IPPROTO_TCP), TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
                        return DisplayConnection(fd: fd)
                    }
                    lastError = DisplaySocketError("connect \(host):\(port)")
                    _ = closeFD(fd)
                }
                cursor = ai.pointee.ai_next
            }
            throw lastError
        }
    }
}

/// A listening socket.
public final class DisplayListener: @unchecked Sendable {
    public let fd: Int32
    public let address: DisplayAddress

    /// Binds and listens. A Unix socket path that exists is replaced only
    /// when it is a socket nobody accepts on.
    public init(address: DisplayAddress) throws {
        self.address = address
        switch address {
        case .unix(let path):
            var st = stat()
            if lstat(path, &st) == 0 {
                guard (st.st_mode & S_IFMT) == S_IFSOCK else {
                    throw DisplaySocketError(message: "\(path) exists and is not a socket")
                }
                if (try? DisplayConnection.connect(to: address)) != nil {
                    throw DisplaySocketError(message: "\(path): another server is listening")
                }
                unlink(path)
            }
            let fd = socket(AF_UNIX, streamType, 0)
            guard fd >= 0 else { throw DisplaySocketError("socket") }
            var addr = try unixAddress(path)
            let r = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            guard r == 0 else { let e = DisplaySocketError("bind \(path)"); _ = closeFD(fd); throw e }
            chmod(path, 0o600)
            self.fd = fd
        case .tcp(let host, let port):
            let fd = socket(AF_INET, streamType, 0)
            guard fd >= 0 else { throw DisplaySocketError("socket") }
            var one: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = port.bigEndian
            guard inet_pton(AF_INET, host == "localhost" ? "127.0.0.1" : host, &addr.sin_addr) == 1 else {
                _ = closeFD(fd)
                throw DisplaySocketError(message: "\(host): not an IPv4 address")
            }
            let r = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            guard r == 0 else { let e = DisplaySocketError("bind \(host):\(port)"); _ = closeFD(fd); throw e }
            self.fd = fd
        }
        guard listen(fd, 4) == 0 else { let e = DisplaySocketError("listen"); _ = closeFD(fd); throw e }
    }

    /// Waits for the next client; nil when the listener was closed.
    public func accept() -> DisplayConnection? {
        while true {
            #if canImport(Glibc)
            let c = Glibc.accept(fd, nil, nil)
            #else
            let c = Darwin.accept(fd, nil, nil)
            #endif
            if c >= 0 {
                if case .tcp = address {
                    var one: Int32 = 1
                    setsockopt(c, Int32(IPPROTO_TCP), TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
                }
                return DisplayConnection(fd: c)
            }
            if errno == EINTR || errno == ECONNABORTED { continue }
            return nil
        }
    }

    public func close() {
        _ = shutdown(fd, Int32(SHUT_RDWR))
        _ = closeFD(fd)
        if case .unix(let path) = address { unlink(path) }
    }
}

private func closeFD(_ fd: Int32) -> Int32 {
    #if canImport(Glibc)
    Glibc.close(fd)
    #else
    Darwin.close(fd)
    #endif
}

private func unixAddress(_ path: String) throws -> sockaddr_un {
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    let capacity = MemoryLayout.size(ofValue: addr.sun_path)
    guard bytes.count < capacity else { throw DisplaySocketError(message: "socket path too long (\(bytes.count) bytes, at most \(capacity - 1)): \(path)") }
    withUnsafeMutableBytes(of: &addr.sun_path) { raw in
        for (i, b) in bytes.enumerated() { raw[i] = b }
        raw[bytes.count] = 0
    }
    #if canImport(Darwin)
    addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    #endif
    return addr
}
