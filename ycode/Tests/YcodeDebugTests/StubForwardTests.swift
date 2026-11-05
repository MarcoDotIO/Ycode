import Foundation
import Testing
@testable import YcodeDebug
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// The loopback forward to a debug stub's Unix socket (debug.md, "The
/// Linux IDE: apps on the simulator").
struct StubForwardTests {
    /// A Unix socket server that answers each read with "<bytes>!" and
    /// accepts one client.
    final class EchoStub: @unchecked Sendable {
        let path: String
        let fd: Int32

        init() throws {
            // Short: sun_path holds about 100 bytes.
            path = "/tmp/ysf-\(getpid())-\(UInt32.random(in: 0...UInt32.max)).sock"
            fd = socket(AF_UNIX, StubForward.streamType, 0)
            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            withUnsafeMutableBytes(of: &addr.sun_path) { raw in
                for (i, b) in path.utf8.enumerated() { raw[i] = b }
            }
            let r = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
            guard r == 0, listen(fd, 1) == 0 else { throw StubForward.Failure.upstream("bind \(errno)") }
            let listener = fd
            Thread {
                let c = accept(listener, nil, nil)
                guard c >= 0 else { return }
                var buf = [UInt8](repeating: 0, count: 4096)
                while true {
                    let n = buf.withUnsafeMutableBytes { read(c, $0.baseAddress, $0.count) }
                    if n <= 0 { break }
                    let reply = Array(buf[0..<n]) + Array("!".utf8)
                    _ = reply.withUnsafeBytes { write(c, $0.baseAddress, $0.count) }
                }
                _ = shutdown(c, Int32(SHUT_RDWR))
            }.start()
        }

        func remove() {
            _ = shutdown(fd, Int32(SHUT_RDWR))
            unlink(path)
        }
    }

    static func connectLoopback(_ port: Int) -> Int32? {
        let fd = socket(AF_INET, StubForward.streamType, 0)
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = UInt16(port).bigEndian
        let r = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        if r != 0 {
            _ = shutdown(fd, Int32(SHUT_RDWR))
            return nil
        }
        return fd
    }

    @Test func forwardsBothWaysToTheUnixSocketForOneClient() throws {
        let stub = try EchoStub()
        defer { stub.remove() }
        #expect(StubForward.unixSocketAccepts("/nonexistent/stub.sock") == false)
        let forward = try StubForward(unixSocket: stub.path)
        defer { forward.close() }
        #expect(forward.port > 0)
        let c = try #require(Self.connectLoopback(forward.port))
        let packet = Array("$qSupported#37".utf8)
        _ = packet.withUnsafeBytes { write(c, $0.baseAddress, $0.count) }
        var got: [UInt8] = []
        var buf = [UInt8](repeating: 0, count: 256)
        while got.count < packet.count + 1 {
            let n = buf.withUnsafeMutableBytes { read(c, $0.baseAddress, $0.count) }
            if n <= 0 { break }
            got += buf[0..<n]
        }
        #expect(String(decoding: got, as: UTF8.self) == "$qSupported#37!")
        // One client only: the listener is closed once the first connects.
        var refused = false
        for _ in 0..<50 {
            if let second = Self.connectLoopback(forward.port) {
                _ = shutdown(second, Int32(SHUT_RDWR))
                Thread.sleep(forTimeInterval: 0.02)
            } else {
                refused = true
                break
            }
        }
        #expect(refused)
        // The client's end of the forward ends when the forward closes.
        forward.close()
        #expect(forward.isClosed)
        let n = buf.withUnsafeMutableBytes { read(c, $0.baseAddress, $0.count) }
        #expect(n <= 0)
        _ = shutdown(c, Int32(SHUT_RDWR))
    }

    @Test func aMissingStubEndsTheClientsConnection() throws {
        let forward = try StubForward(unixSocket: "/nonexistent/stub.sock")
        let c = try #require(Self.connectLoopback(forward.port))
        var buf = [UInt8](repeating: 0, count: 16)
        let n = buf.withUnsafeMutableBytes { read(c, $0.baseAddress, $0.count) }
        #expect(n <= 0)
        _ = shutdown(c, Int32(SHUT_RDWR))
        for _ in 0..<100 where !forward.isClosed { Thread.sleep(forTimeInterval: 0.01) }
        #expect(forward.isClosed)
    }
}
