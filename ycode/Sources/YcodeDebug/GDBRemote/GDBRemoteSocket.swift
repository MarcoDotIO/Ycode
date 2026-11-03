#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif
import Foundation

// Sockets for the stub (`debug-stub.md` §7): a listener on a Unix socket
// path (forwarded to the Mac by `ssh -L`) or a TCP port on the loopback
// interface, and a connection over a file descriptor.

public final class GDBRemoteFDConnection: GDBRemoteConnection, @unchecked Sendable {
    public let fd: Int32
    private var closed = false
    private let lock = NSLock()

    public init(fd: Int32) {
        self.fd = fd
        #if canImport(Darwin)
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        #endif
    }

    public func receive() -> [UInt8]? {
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n > 0 { return Array(buffer[0..<n]) }
            if n < 0 && errno == EINTR { continue }
            return nil
        }
    }

    public func send(_ bytes: [UInt8]) {
        var offset = 0
        while offset < bytes.count {
            let n = bytes[offset...].withUnsafeBytes { raw -> Int in
                #if canImport(Glibc)
                return Glibc.send(fd, raw.baseAddress, raw.count, Int32(MSG_NOSIGNAL))
                #else
                return Darwin.send(fd, raw.baseAddress, raw.count, 0)
                #endif
            }
            if n > 0 { offset += n; continue }
            if n < 0 && errno == EINTR { continue }
            return
        }
    }

    public func close() {
        lock.withLockFallback {
            guard !closed else { return }
            closed = true
            shutdown(fd, Int32(SHUT_RDWR))
            #if canImport(Glibc)
            Glibc.close(fd)
            #else
            Darwin.close(fd)
            #endif
        }
    }
}

/// A listening socket.
public final class GDBRemoteListener: @unchecked Sendable {
    public let fd: Int32
    public let description: String
    private let unixPath: String?
    /// The socket file's inode once bound: `close` removes the path only
    /// while it is still this listener's (a later run of the same device
    /// may have bound the path meanwhile).
    private var unixInode: UInt64 = 0

    /// `unix:<path>`, `<host>:<port>` or `<port>` (loopback).
    public init(address: String) throws {
        if address.hasPrefix("unix:") {
            let path = String(address.dropFirst(5))
            unixPath = path
            description = "unix:" + path
            fd = socket(AF_UNIX, Self.streamType, 0)
            guard fd >= 0 else { throw GDBRemoteError(1, "socket: \(String(cString: strerror(errno)))") }
            unlink(path)
            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            let bytes = Array(path.utf8)
            guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { throw GDBRemoteError(1, "socket path too long: \(path)") }
            withUnsafeMutableBytes(of: &addr.sun_path) { raw in
                for (i, b) in bytes.enumerated() { raw[i] = b }
                raw[bytes.count] = 0
            }
            let r = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            guard r == 0 else { throw GDBRemoteError(1, "bind \(path): \(String(cString: strerror(errno)))") }
            var st = stat()
            if stat(path, &st) == 0 { unixInode = UInt64(st.st_ino) }
        } else {
            unixPath = nil
            let parts = address.split(separator: ":")
            guard let portText = parts.last, let port = UInt16(portText) else { throw GDBRemoteError(1, "bad address \(address)") }
            let hostText = parts.count > 1 ? String(parts[0]) : "127.0.0.1"
            description = "\(hostText):\(port)"
            fd = socket(AF_INET, Self.streamType, 0)
            guard fd >= 0 else { throw GDBRemoteError(1, "socket: \(String(cString: strerror(errno)))") }
            var one: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = port.bigEndian
            guard inet_pton(AF_INET, hostText, &addr.sin_addr) == 1 else { throw GDBRemoteError(1, "bad host \(hostText)") }
            let r = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            guard r == 0 else { throw GDBRemoteError(1, "bind \(address): \(String(cString: strerror(errno)))") }
        }
        guard listen(fd, 4) == 0 else { throw GDBRemoteError(1, "listen: \(String(cString: strerror(errno)))") }
    }

    private static var streamType: Int32 {
        #if canImport(Glibc)
        Int32(SOCK_STREAM.rawValue)
        #else
        SOCK_STREAM
        #endif
    }

    /// Blocks for the next client; nil when the listener was closed.
    public func accept() -> GDBRemoteFDConnection? {
        while true {
            #if canImport(Glibc)
            let c = Glibc.accept(fd, nil, nil)
            #else
            let c = Darwin.accept(fd, nil, nil)
            #endif
            if c >= 0 {
                var one: Int32 = 1
                setsockopt(c, Int32(IPPROTO_TCP), TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
                return GDBRemoteFDConnection(fd: c)
            }
            if errno == EINTR { continue }
            return nil
        }
    }

    public func close() {
        shutdown(fd, Int32(SHUT_RDWR))
        #if canImport(Glibc)
        Glibc.close(fd)
        #else
        Darwin.close(fd)
        #endif
        if let unixPath {
            var st = stat()
            if stat(unixPath, &st) == 0, UInt64(st.st_ino) == unixInode { unlink(unixPath) }
        }
    }
}
