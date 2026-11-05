import CoreGraphics
import Foundation
import Testing
import YcodeDisplayStream
@testable import YcodeDeviceUI

/// The macOS device window over a transport other than a socket address
/// (`ycode-sim-viewer --link`, the Linux viewer's link, docs/SIMULATOR-UX.md):
/// the connection says hello through it and reads the server's answer.
@Suite(.serialized) struct LinkTransportTests {
    /// A transport that answers the client's hello with a server hello.
    final class Loop: DisplayTransport, @unchecked Sendable {
        let lock = NSLock()
        var sent: [[UInt8]] = []
        var inbox: [[UInt8]]
        var closed = false
        init(reply: [UInt8]) { inbox = [reply] }
        func send(_ bytes: [UInt8]) throws { lock.withLock { sent.append(bytes) } }
        func receive(max: Int) -> [UInt8]? {
            while true {
                if let next = lock.withLock({ inbox.isEmpty ? nil : inbox.removeFirst() }) { return next }
                if lock.withLock({ closed }) { return nil }
                Thread.sleep(forTimeInterval: 0.01)
            }
        }
        func close() { lock.withLock { closed = true } }
    }

    @MainActor final class Seen: ViewerConnectionDelegate {
        var hello: DisplayServerHello?
        func connection(_ c: ViewerConnection, phase: String, detail: String?) {}
        func connection(_ c: ViewerConnection, hello: DisplayServerHello) { self.hello = hello }
        func connection(_ c: ViewerConnection, status: DisplayStatus) {}
        func connection(_ c: ViewerConnection, image: CGImage, frame: DisplayFrame, receivedAt: UInt64) {}
        func connection(_ c: ViewerConnection, notice: String) {}
        func connection(_ c: ViewerConnection, screenshot png: [UInt8], token: UInt32) {}
        func connection(_ c: ViewerConnection, pongToken token: UInt64, rttMilliseconds: Double) {}
        func connection(_ c: ViewerConnection, displayState: DisplayPanelState) {}
    }

    @MainActor @Test func helloGoesThroughTheSuppliedTransport() async throws {
        let hello = DisplayServerHello(deviceName: "iPhone-18-Pro", model: "iPhone18,1", pixelWidth: 1206, pixelHeight: 2622, scale: 3,
                                       encodings: ["jpeg"], touch: true, keyboard: true, buttons: ["home"], rotation: false)
        let loop = Loop(reply: DisplayMessage.hello(hello).encoded())
        let c = ViewerConnection(address: .unix("/nonexistent"), settings: DisplayClientHello(client: "test"), connector: { loop })
        let seen = Seen()
        c.delegate = seen
        c.start()
        defer { c.stop() }
        for _ in 0..<200 where seen.hello == nil { try await Task.sleep(nanoseconds: 10_000_000) }
        #expect(seen.hello?.deviceName == "iPhone-18-Pro")
        #expect(loop.lock.withLock { loop.sent.first } == DisplayMessage.clientHello(DisplayClientHello(client: "test")).encoded())
        #expect(c.send(.ping(token: 7)))
    }
}
