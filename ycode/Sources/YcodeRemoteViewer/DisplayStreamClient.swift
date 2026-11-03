// The portable viewer's side of the display stream (display-stream.md §2–§5,
// §12): connects and reconnects through a transport (a Unix or TCP socket,
// or Ycode's own secure link, sim-link.md), decodes frames into a
// StreamCanvas on its own thread, keeps the clock estimate, the input
// sequence and the latency probes, and tells the front end what happened
// through `onEvent` (called on the connection thread; the front end moves
// work to its own thread). Foundation only: the Linux window and the IDE
// canvas use it.

import Foundation
import YcodeDisplayStream

/// A frame as the viewer received it.
public struct ReceivedFrame: Sendable {
    public var frame: DisplayFrameSummary
    /// Client ns: the last byte arrived, the canvas holds it.
    public var receivedAt: UInt64
    public var decodedAt: UInt64
    /// The headset viewer's tag of this frame (xr-viewer.md §4.1), when the
    /// server sent one; the image is then in that view's canvas.
    public var view: XRFrameView?
}

/// A frame without its pixel data.
public struct DisplayFrameSummary: Sendable, Equatable {
    public var sequence: UInt64, guestFrame: UInt64, serverNanoseconds: UInt64, inputSequence: UInt32
    public var width: Int, height: Int, encoding: DisplayEncoding, isFull: Bool, tiles: Int, bytes: Int

    public init(_ f: DisplayFrame) {
        (sequence, guestFrame, serverNanoseconds, inputSequence) = (f.sequence, f.guestFrame, f.serverNanoseconds, f.inputSequence)
        (width, height, encoding, isFull, tiles, bytes) = (f.width, f.height, f.encoding, f.isFull, f.tiles.count, f.byteCount)
    }
}

public enum DisplayClientEvent: Sendable {
    case phase(String, detail: String?)
    case hello(DisplayServerHello)
    case status(DisplayStatus)
    case displayState(DisplayPanelState)
    /// A new image is in `canvas` (fetch it with `withCanvas`).
    case frame(ReceivedFrame)
    case notice(String)
    case screenshot(token: UInt32, png: [UInt8])
    case commandReply(token: UInt32, text: String)
    /// An input event reached the screen: label, ms from sending it to the
    /// first frame that includes it (received and decoded).
    case latency(label: String, sequence: UInt32, milliseconds: Double)
    case pong(rttMilliseconds: Double)
    case timing(DisplayFrameTiming)
    /// Foveated streaming: a frame's full-resolution inset (xr-viewer.md §4.5).
    case inset(XRInset)
}

public final class DisplayStreamClient: @unchecked Sendable {
    public let connect: @Sendable () throws -> DisplayTransport
    public private(set) var settings: DisplayClientHello
    public var onEvent: @Sendable (DisplayClientEvent) -> Void = { _ in }
    /// How long to wait between connection attempts.
    public var retryInterval: TimeInterval = 1
    /// Reconnect after the connection ends (false: one connection).
    public var reconnects = true
    /// The device's sound (§15), on the connection thread as packets arrive
    /// (with the arrival time), not through `onEvent`.
    public var onAudio: (@Sendable (DisplayAudio, UInt64) -> Void)?
    /// The headset mode's depth of each picture (frame depth 0x0C, xr-depth.md
    /// §4), on the connection thread just after its frame was decoded (with the
    /// arrival time), not through `onEvent`.
    public var onDepth: (@Sendable (XRFrameDepth, UInt64) -> Void)?
    /// The room's environment (0x0D), on the connection thread.
    public var onEnvironment: (@Sendable (XREnvironment) -> Void)?

    private let lock = NSLock()
    private var transport: DisplayTransport?
    private var stopped = false
    private var inputSequence: UInt32 = 0
    private var pings: [UInt64: UInt64] = [:]
    private var nextPing: UInt64 = 0
    private var nextToken: UInt32 = 0
    private var probes: [(seq: UInt32, sent: UInt64, label: String)] = []
    private var canvas: StreamCanvas?
    /// The headset mode's per-view canvases (left, right; mono is `canvas`)
    /// and the tag waiting for its frame.
    private var viewCanvases: [XRView: StreamCanvas] = [:]
    private var pendingView: XRFrameView?
    private var thread: Thread?
    private var finished = false
    /// Another viewer took the display over: no reconnecting until `takeBack()`.
    private var takenOver = false

    // Statistics (under the lock).
    private var clockState = ClockSync()
    /// The clock estimate (§12.2).
    public var clock: ClockSync { lock.withLock { clockState } }
    private var bytesIn = 0, framesIn = 0, decodeNs: UInt64 = 0
    /// The server's frame timings by sequence, until the frame is presented.
    private var timings: [UInt64: DisplayFrameTiming] = [:]
    public private(set) var hello: DisplayServerHello?
    /// The server honours this client's `frameWindow` (display-stream.md §4.2).
    private var acksFrames = false

    public init(settings: DisplayClientHello, connect: @escaping @Sendable () throws -> DisplayTransport) {
        self.settings = settings
        self.connect = connect
    }

    /// A client of a socket address (`unix:<path>`, `<host>:<port>`, `<port>`).
    public convenience init(address: DisplayAddress, settings: DisplayClientHello) {
        self.init(settings: settings) { try DisplayConnection.connect(to: address) }
    }

    public func start() {
        let t = Thread { [self] in run() }
        t.name = "display-client"
        t.qualityOfService = .userInteractive
        thread = t
        t.start()
    }

    public func stop() {
        let t = lock.withLock { () -> DisplayTransport? in stopped = true; return transport }
        t?.close()
    }

    public var isStopped: Bool { lock.withLock { stopped } }

    /// Another viewer has the display (display-stream.md §1.1).
    public var isTakenOver: Bool { lock.withLock { takenOver } }

    /// Connects again after a takeover (taking the display back).
    public func takeBack() { lock.withLock { takenOver = false } }
    public var hasEnded: Bool { lock.withLock { finished } }

    /// (bytes, frames, total decode ns) received so far.
    public var statistics: (bytes: Int, frames: Int, decodeNanoseconds: UInt64) { lock.withLock { (bytesIn, framesIn, decodeNs) } }

    /// The canvas of the current stream (nil before the first frame).
    public var currentCanvas: StreamCanvas? { lock.withLock { canvas } }

    /// The canvas of one view (the headset mode); `.mono` is `currentCanvas`.
    public func canvas(for view: XRView) -> StreamCanvas? {
        lock.withLock { view == .mono ? canvas : viewCanvases[view] }
    }

    /// The server timing of a frame (once; it is forgotten after).
    public func takeTiming(sequence: UInt64) -> DisplayFrameTiming? {
        lock.withLock { timings.removeValue(forKey: sequence) }
    }

    private func emit(_ e: DisplayClientEvent) { onEvent(e) }

    private func run() {
        var attempt = 0
        defer { lock.withLock { finished = true } }
        while !isStopped {
            attempt += 1
            emit(.phase("connecting", detail: attempt > 1 ? "attempt \(attempt)" : nil))
            let t: DisplayTransport
            do {
                t = try connect()
            } catch {
                if !reconnects { emit(.phase("disconnected", detail: "\(error)")); return }
                Thread.sleep(forTimeInterval: retryInterval)
                continue
            }
            lock.withLock { transport = t }
            if isStopped { t.close(); break }
            try? t.send(DisplayMessage.clientHello(settings).encoded())
            var parser = DisplayMessageParser()
            var gotHello = false
            loop: while let bytes = t.receive(max: 1 << 20) {
                lock.withLock { bytesIn += bytes.count }
                parser.append(bytes)
                do {
                    while let m = try parser.next() {
                        if case .hello = m { gotHello = true }
                        handle(m)
                    }
                } catch {
                    emit(.notice("protocol error: \(error)"))
                    break loop
                }
            }
            t.close()
            lock.withLock { transport = nil; canvas = nil; viewCanvases = [:]; pendingView = nil }
            if isStopped { break }
            if isTakenOver {
                emit(.phase(DisplayNotice.takenOverPhase, detail: "another viewer has the display"))
                while isTakenOver && !isStopped { Thread.sleep(forTimeInterval: 0.05) }
                attempt = 0
                continue
            }
            emit(.phase("disconnected", detail: gotHello ? "the device stopped or the link dropped" : nil))
            if !reconnects { return }
            Thread.sleep(forTimeInterval: retryInterval)
        }
    }

    private func handle(_ m: DisplayMessage) {
        switch m {
        case .hello(let h):
            lock.withLock { hello = h; acksFrames = h.frameAcks == true && (settings.frameWindow ?? 0) > 0 }
            emit(.hello(h))
            // A first clock estimate at once (audio and stage times need it).
            for _ in 0..<3 { ping() }
        case .audio(let a):
            onAudio?(a, viewerNanoseconds())
        case .status(let s): emit(.status(s))
        case .notice(let text):
            if text == DisplayNotice.takenOver { lock.withLock { takenOver = true } }
            emit(.notice(text))
        case .displayState(let state):
            lock.withLock { canvas = nil; viewCanvases = [:] }
            emit(.displayState(state))
        case .screenshot(let token, let png): emit(.screenshot(token: token, png: png))
        case .commandReply(let token, let text): emit(.commandReply(token: token, text: text))
        case .pong(let token, let server):
            let now = viewerNanoseconds()
            guard let sent = lock.withLock({ pings.removeValue(forKey: token) }) else { return }
            lock.withLock { clockState.add(sent: sent, server: server, received: now) }
            emit(.pong(rttMilliseconds: Double(now - sent) / 1e6))
        case .frameTiming(let t):
            lock.withLock {
                timings[t.sequence] = t
                if timings.count > 256 { timings.removeAll() }
            }
            emit(.timing(t))
        case .frameView(let v):
            lock.withLock { pendingView = v }
        case .inset(let i):
            emit(.inset(i))
        case .frameDepth(let d):
            onDepth?(d, viewerNanoseconds())
        case .environment(let e):
            onEnvironment?(e)
        case .frame(let f):
            let received = viewerNanoseconds()
            let tag = lock.withLock { () -> XRFrameView? in
                defer { pendingView = nil }
                return pendingView?.frameSequence == f.sequence ? pendingView : nil
            }
            let view = tag?.view ?? .mono
            var c = lock.withLock { view == .mono ? canvas : viewCanvases[view] }
            if c == nil || c!.width != f.width || c!.height != f.height {
                c = StreamCanvas(width: f.width, height: f.height)
                lock.withLock { if view == .mono { canvas = c } else { viewCanvases[view] = c } }
                if !f.isFull { send(.keyframeRequest) }
            }
            guard let c else { return }
            if !c.apply(f) { send(.keyframeRequest) }
            let decoded = viewerNanoseconds()
            let acks = lock.withLock { () -> Bool in
                framesIn += 1
                decodeNs += decoded - received
                return acksFrames
            }
            // Decoded: room for the next picture (display-stream.md §4.2).
            if acks { send(.frameAck(sequence: f.sequence)) }
            emit(.frame(ReceivedFrame(frame: DisplayFrameSummary(f), receivedAt: received, decodedAt: decoded, view: tag)))
            if f.inputSequence > 0 {
                let done = lock.withLock { () -> [(UInt32, UInt64, String)] in
                    var out: [(UInt32, UInt64, String)] = []
                    while let p = probes.first, p.seq <= f.inputSequence { probes.removeFirst(); out.append(p) }
                    return out
                }
                for (seq, sent, label) in done {
                    emit(.latency(label: label, sequence: seq, milliseconds: Double(decoded - sent) / 1e6))
                }
            }
        default:
            break
        }
    }

    // MARK: Sending (any thread)

    @discardableResult
    public func send(_ m: DisplayMessage) -> Bool {
        guard let t = lock.withLock({ transport }) else { return false }
        do { try t.send(m.encoded()) } catch { return false }
        return true
    }

    public var isConnected: Bool { lock.withLock { transport != nil } }

    /// Sends an input event with the next sequence number; returns it (0:
    /// not connected). A `label` makes it a latency probe.
    @discardableResult
    public func sendInput(label: String? = nil, _ make: (UInt32) -> DisplayInput) -> UInt32 {
        let seq = lock.withLock { () -> UInt32 in inputSequence &+= 1; return inputSequence }
        let sentAt = viewerNanoseconds()
        guard send(.input(make(seq))) else { return 0 }
        if let label {
            lock.withLock {
                probes.append((seq, sentAt, label))
                probes.removeAll { sentAt - $0.sent > 10_000_000_000 }
            }
        }
        return seq
    }

    public func ping() {
        let token = lock.withLock { () -> UInt64 in
            nextPing += 1
            pings[nextPing] = viewerNanoseconds()
            if pings.count > 64 { pings.removeAll() }
            return nextPing
        }
        send(.ping(token: token))
    }

    /// A fresh token for a screenshot request or a command.
    public func token() -> UInt32 { lock.withLock { nextToken &+= 1; return nextToken } }

    public func updateSettings(_ s: DisplayClientHello) {
        lock.withLock { settings = s }
        send(.clientHello(s))
    }
}
