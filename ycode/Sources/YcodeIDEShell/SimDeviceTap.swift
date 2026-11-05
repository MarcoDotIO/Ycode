// A tap on a Ycode simulator device through its display socket
// (specs/simulator/display-stream.md §5.1, as scripts/ycode-display-probe's
// `tap`), for the debugger's automation: the ShellDriver walk and the
// end-to-end test tap the sample app's button while the app runs under the
// debugger. The socket is the host's `<home>/run/<device>.sock`.

import Foundation
import YcodeDisplayStream
import YcodeSimLink

public enum SimDeviceTap {
    public struct Failure: Error, CustomStringConvertible { public let description: String }

    /// Connects to `address` (`unix:<path>`), reads the server's hello, and
    /// taps at (`x`, `y`) in device points, or the screen's centre when nil.
    /// Returns the point tapped.
    @discardableResult
    public static func tap(address: String, x: Double? = nil, y: Double? = nil, holdMilliseconds: Int = 80) throws -> (x: Double, y: Double) {
        guard let a = DisplayAddress(address) else { throw Failure(description: "not a display address: \(address)") }
        let c = try DisplayConnection.connect(to: a)
        defer { c.close() }
        try c.send(.clientHello(DisplayClientHello(client: "ycode-ide automation", maxFPS: 1)))
        var splitter = MessageSplitter()
        var hello: DisplayServerHello?
        let deadline = Date().addingTimeInterval(20)
        while hello == nil, Date() < deadline, let bytes = c.receive() {
            splitter.append(bytes)
            while hello == nil, let m = splitter.next(), m.count >= 5 {
                if case .hello(let h)? = try? DisplayMessage.decode(type: m[4], payload: m[5...]) { hello = h }
            }
        }
        guard let hello else { throw Failure(description: "no hello from \(address)") }
        let px = x ?? hello.pointWidth / 2, py = y ?? hello.pointHeight / 2
        try c.send(.input(.touch(sequence: 1, contacts: [TouchContact(finger: 0, phase: .began, x: Float(px), y: Float(py))])))
        Thread.sleep(forTimeInterval: Double(holdMilliseconds) / 1000)
        try c.send(.input(.touch(sequence: 2, contacts: [TouchContact(finger: 0, phase: .ended, x: Float(px), y: Float(py))])))
        // Let the server read the input before the connection closes.
        Thread.sleep(forTimeInterval: 0.3)
        return (px, py)
    }
}
