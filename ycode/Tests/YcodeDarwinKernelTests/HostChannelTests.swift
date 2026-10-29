import Foundation
import Testing
import YcodeDarwinABI
@testable import YcodeDarwinKernel

/// FEAT (simulator-features.md "Ycode implementation" §I.2): a host channel
/// served outside the kernel. A guest connect to the served path succeeds
/// with no guest listener; bytes go both ways; the server hears the open and
/// the close; an unserved path is refused again after stopServing.
@Suite(.serialized) struct HostChannelTests {
    final class Echo: HostChannelServer, @unchecked Sendable {
        let lock = NSLock()
        var opened = 0, closed = 0
        var got: [UInt8] = []
        func channelOpened(_ c: HostChannelConnection) { lock.withLock { opened += 1 } }
        func channel(_ c: HostChannelConnection, received bytes: [UInt8]) {
            lock.withLock { got += bytes }
            c.send(bytes.reversed())
        }
        func channelClosed(_ c: HostChannelConnection) { lock.withLock { closed += 1 } }
    }

    @Test func bytesTravelBothWays() throws {
        let path = "/private/var/run/dev.ycode.test-channel"
        let echo = Echo()
        HostStreamSockets.serve(paths: [path], with: echo)
        defer { HostStreamSockets.stopServing(paths: [path]) }
        let e = try DEnv()
        let s = e.socket()
        #expect(e.connect(s, path).value == 0)
        #expect(e.sendBytes(s, [1, 2, 3]).value == 3)
        var received: [UInt8] = []
        let deadline = KernelClock.deadline(afterNanoseconds: 5_000_000_000)
        while KernelClock.now() < deadline, received.count < 3 {
            _ = e.poll(s, events: 1, timeout: 100)
            e.setNonBlocking(s)
            let (r, bytes) = e.receiveBytes(s)
            if r.value != nil { received += bytes }
        }
        #expect(received == [3, 2, 1])
        e.close(s)
        let until = Date().addingTimeInterval(5)
        while Date() < until, echo.lock.withLock({ echo.closed }) == 0 { usleep(10_000) }
        #expect(echo.lock.withLock { (echo.opened, echo.closed, echo.got) } == (1, 1, [1, 2, 3]))
        HostStreamSockets.stopServing(paths: [path])
        let t = e.socket()
        #expect(e.connect(t, path).value == nil)
        e.close(t)
    }
}
