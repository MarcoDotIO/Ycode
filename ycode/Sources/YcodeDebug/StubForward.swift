// A one-connection loopback forward to a gdb-remote stub's Unix socket
// (specs/ide/debug.md, "The Linux IDE: apps on the simulator";
// specs/simulator/debug-stub.md §3). lldb-dap reaches a stub only by TCP
// (`gdb-remote-port`), while ycode-simd serves it on a Unix socket in the
// simulator host's run folder. The forward listens on 127.0.0.1 with a port
// the system picks, accepts exactly one client (then closes the listener,
// so no other user of a shared machine can reach the stub through it), and
// copies bytes both ways until either side closes.
//
// The upstream is a closure that returns a connected file descriptor, so a
// forward over Ycode's link (#50) can reuse the client side.

import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

public final class StubForward: @unchecked Sendable {
    public enum Failure: Error, CustomStringConvertible {
        case listen(Int32), upstream(String)
        public var description: String {
            switch self {
            case .listen(let e): "could not listen on a loopback port (errno \(e))"
            case .upstream(let s): s
            }
        }
    }

    /// The loopback port lldb-dap connects to.
    public let port: Int
    private let listener: Int32
    private let upstream: @Sendable () throws -> Int32
    private let lock = NSLock()
    private var closed = false
    private var listening = true
    private var fds: [Int32] = []

    /// Listens now; `upstream` is called when the client connects.
    public init(upstream: @escaping @Sendable () throws -> Int32) throws {
        self.upstream = upstream
        let fd = socket(AF_INET, Self.streamType, 0)
        guard fd >= 0 else { throw Failure.listen(errno) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        let size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) } }
        guard bound == 0, listen(fd, 1) == 0 else {
            let e = errno
            _ = Self.closeFD(fd)
            throw Failure.listen(e)
        }
        var len = size
        _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        listener = fd
        port = Int(UInt16(bigEndian: addr.sin_port))
        let t = Thread { [self] in serve() }
        t.name = "ycode-stub-forward"
        t.start()
    }

    /// A forward to the stub's Unix socket at `path`.
    public convenience init(unixSocket path: String) throws {
        try self.init { try StubForward.connect(unixSocket: path) }
    }

    /// Ends the forward: the listener and both connections close.
    public func close() {
        let toClose: [Int32] = lock.withLock {
            guard !closed else { return [] }
            closed = true
            // Each descriptor is closed once: a number closed twice may by
            // then belong to another socket of this process.
            let open = (listening ? [listener] : []) + fds
            listening = false
            fds = []
            return open
        }
        for fd in toClose { shutdown(fd, Int32(SHUT_RDWR)); _ = Self.closeFD(fd) }
    }

    public var isClosed: Bool { lock.withLock { closed } }

    deinit { close() }

    private func serve() {
        let client = accept(listener, nil, nil)
        // One client only: the listener closes at once.
        let open: Bool = lock.withLock {
            if listening {
                _ = Self.closeFD(listener)
                listening = false
            }
            return !closed && client >= 0
        }
        guard open else {
            if client >= 0 { _ = Self.closeFD(client) }
            close()
            return
        }
        let up: Int32
        do { up = try upstream() } catch {
            _ = Self.closeFD(client)
            close()
            return
        }
        let keep: Bool = lock.withLock {
            guard !closed else { return false }
            fds = [client, up]
            return true
        }
        guard keep else {
            _ = Self.closeFD(client)
            _ = Self.closeFD(up)
            return
        }
        Self.pump(client, up)
        close()
    }

    /// Copies both ways until one side ends.
    static func pump(_ a: Int32, _ b: Int32) {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        var polls = [pollfd(fd: a, events: Int16(POLLIN), revents: 0), pollfd(fd: b, events: Int16(POLLIN), revents: 0)]
        while true {
            let n = poll(&polls, 2, -1)
            if n < 0 { if errno == EINTR { continue }; return }
            for i in 0..<2 where polls[i].revents != 0 {
                let from = polls[i].fd, to = polls[1 - i].fd
                let got = buffer.withUnsafeMutableBytes { read(from, $0.baseAddress, $0.count) }
                if got <= 0 { return }
                var sent = 0
                while sent < got {
                    let w = buffer.withUnsafeBytes { write(to, $0.baseAddress! + sent, got - sent) }
                    if w < 0 { if errno == EINTR { continue }; return }
                    sent += w
                }
            }
        }
    }

    /// A connected stream socket to the Unix socket at `path`.
    public static func connect(unixSocket path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, streamType, 0)
        guard fd >= 0 else { throw Failure.upstream("socket: errno \(errno)") }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard bytes.count < capacity else {
            _ = closeFD(fd)
            throw Failure.upstream("the socket path is too long: \(path)")
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in bytes.enumerated() { raw[i] = b }
            raw[bytes.count] = 0
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let r = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connectFD(fd, $0, size) } }
        guard r == 0 else {
            let e = errno
            _ = closeFD(fd)
            throw Failure.upstream("cannot connect to \(path) (errno \(e))")
        }
        return fd
    }

    /// True when something listens on the Unix socket at `path`.
    public static func unixSocketAccepts(_ path: String) -> Bool {
        guard let fd = try? connect(unixSocket: path) else { return false }
        _ = closeFD(fd)
        return true
    }

    static var streamType: Int32 {
        #if canImport(Glibc)
        Int32(SOCK_STREAM.rawValue)
        #else
        SOCK_STREAM
        #endif
    }

    private static func closeFD(_ fd: Int32) -> Int32 {
        #if canImport(Glibc)
        Glibc.close(fd)
        #else
        Darwin.close(fd)
        #endif
    }

    private static func connectFD(_ fd: Int32, _ addr: UnsafePointer<sockaddr>, _ len: socklen_t) -> Int32 {
        #if canImport(Glibc)
        Glibc.connect(fd, addr, len)
        #else
        Darwin.connect(fd, addr, len)
        #endif
    }
}
