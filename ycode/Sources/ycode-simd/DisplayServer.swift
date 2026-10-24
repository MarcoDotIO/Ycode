// ycode-simd --display-server <address>: a live view of the device's display
// and an input channel for a viewer (specs/simulator/display-stream.md).
//
// The headless SimFramebuffer library rewrites its frame record (the
// presented IOSurface and a frame counter) on every swap. The server polls
// that record (a 96-byte pread every few milliseconds, only while a client
// is connected), compares the presented surface with the image the client
// already has in tiles, and sends the changed rectangles, JPEG- or
// zlib-encoded, at most `maxFPS` times a second. A slow link only delays
// the next update: changes accumulate against the client's image, so the
// newest pixels always win. Nothing runs before a client connects except
// one thread blocked in accept().

#if os(Linux) && arch(arm64)
import CYcodeCodec
import Foundation
import Glibc
import YcodeDisplayStream
import YcodeHostServices
import YcodeHypervisor

/// Where viewer input goes (InputBridge.swift).
protocol GuestInputSink: AnyObject {
    var acceptsTouch: Bool { get }
    var acceptsKeyboard: Bool { get }
    var buttons: [DisplayButton] { get }
    /// Delivers one event to the guest; false when it was dropped.
    func deliver(_ input: DisplayInput) -> Bool
    /// The viewer went away: touches still down are cancelled, keys and
    /// buttons still down are released (no stuck state, hid-input.md §7.5).
    func reset()
}

/// Names the calling thread (seen in /proc and debuggers).
func nameThread(_ name: String) { ycodec_name_thread(name) }

final class FrameRecordReader {
    let path: String
    private var fd: Int32 = -1
    private var reads = 0

    init(path: String) { self.path = path }
    deinit { if fd >= 0 { close(fd) } }

    func read() -> FrameRecord? {
        reads += 1
        if fd >= 0, reads % 256 == 0 {
            // The file was replaced (a new boot of the device directory): reopen.
            var st = stat()
            if fstat(fd, &st) != 0 || st.st_nlink == 0 { close(fd); fd = -1 }
        }
        if fd < 0 {
            fd = open(path, O_RDONLY | O_CLOEXEC)
            if fd < 0 { return nil }
        }
        var buf = [UInt8](repeating: 0, count: 128)
        let n = buf.withUnsafeMutableBytes { pread(fd, $0.baseAddress, 128, 0) }
        guard n > 0 else { return nil }
        return FrameRecord.parse(Substring(String(decoding: buf[0..<n], as: UTF8.self)))
    }
}

/// The display server's timing trace (display-stream.md §10), written only
/// with YCODE_DISPLAY_TIMING=1: text lines, times in host CLOCK_MONOTONIC
/// nanoseconds, guest times in guest mach ticks.
///   sync <host ns> <guest ticks>                          (once a second)
///   input <seq> <kind> <received ns> <handed to HID ns> <HID sequence>
///   record <guest frame> <seen ns>
///   frame <seq> <guest frame> <scan start ns> <encoded ns> <sent ns> <bytes> <tiles> <input seq>
final class DisplayTrace: @unchecked Sendable {
    private let lock = NSLock()
    private let handle: FileHandle
    private let guestClock: (() -> UInt64?)?
    private var nextSync: UInt64 = 0

    init?(path: String, guestClock: (() -> UInt64?)?) {
        guard FileManager.default.createFile(atPath: path, contents: nil), let h = FileHandle(forWritingAtPath: path) else { return nil }
        handle = h
        self.guestClock = guestClock
    }

    func line(_ text: String) {
        let now = monotonicNanoseconds()
        lock.withLock {
            var out = ""
            if now >= nextSync, let g = guestClock?() {
                // Read the two clocks back to back; the pair maps guest ticks to host time.
                out += "sync \(monotonicNanoseconds()) \(g)\n"
                nextSync = now + 1_000_000_000
            }
            out += text + "\n"
            handle.write(Data(out.utf8))
        }
    }
}

/// Wakes a waiter as soon as the frame record is rewritten (inotify on its
/// directory; the guest's pwrite reaches the host file), so a new frame is
/// scanned within a millisecond instead of at the next 4–8 ms poll. The
/// polls stay as the fallback (no inotify, a replaced directory).
final class FrameRecordWatcher: @unchecked Sendable {
    private let fd: Int32
    private let name: String
    private let lock = NSLock()
    private var stopped = false

    init?(path: String, onChange: @escaping @Sendable () -> Void) {
        let dir = (path as NSString).deletingLastPathComponent
        name = (path as NSString).lastPathComponent
        fd = inotify_init1(Int32(IN_CLOEXEC | IN_NONBLOCK))
        guard fd >= 0 else { return nil }
        let mask = UInt32(IN_MODIFY | IN_CLOSE_WRITE | IN_CREATE | IN_MOVED_TO)
        guard inotify_add_watch(fd, dir, mask) >= 0 else { close(fd); return nil }
        let t = Thread { [self] in run(onChange) }
        t.name = "display-watch"
        t.start()
    }

    func stop() { lock.withLock { stopped = true } }

    private func run(_ onChange: @Sendable () -> Void) {
        nameThread("display-watch")
        var buf = [UInt8](repeating: 0, count: 4096)
        while !lock.withLock({ stopped }) {
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&p, 1, 100) > 0 else { continue }
            let n = buf.withUnsafeMutableBytes { Glibc.read(fd, $0.baseAddress, $0.count) }
            guard n > 0 else { continue }
            // Events: {wd i32, mask u32, cookie u32, len u32, name[len]}.
            var off = 0, hit = false
            buf.withUnsafeBytes { b in
                while off + 16 <= n {
                    let len = Int(b.load(fromByteOffset: off + 12, as: UInt32.self))
                    if len > 0, off + 16 + len <= n {
                        let raw = b[(off + 16)..<(off + 16 + len)]
                        let s = String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
                        if s == name { hit = true }
                    }
                    off += 16 + len
                }
            }
            if hit { onChange() }
        }
        close(fd)
    }
}

final class DisplayServer: @unchecked Sendable {
    let listener: DisplayListener
    let statePath: String
    let surfaces: IOSurfaceHostService
    let started: UInt64
    let input: GuestInputSink?
    let screen: (width: Int, height: Int, scale: Double)
    /// The device's model identifier (hello `model`; the device type's).
    var model = DeviceType.default.modelIdentifier
    let log: (String) -> Void
    /// The timing trace (YCODE_DISPLAY_TIMING=1), or nil.
    var trace: DisplayTrace?
    /// The HID service's last sequence number (input trace lines).
    var hidSequence: (() -> UInt64)?
    private let lock = NSLock()
    private var current: DisplayClientSession?
    private var stopping = false
    private var stopMessage: String?

    init(address: DisplayAddress, statePath: String, surfaces: IOSurfaceHostService, started: UInt64,
         screen: (width: Int, height: Int, scale: Double), input: GuestInputSink?, log: @escaping (String) -> Void) throws {
        listener = try DisplayListener(address: address)
        self.statePath = statePath
        self.surfaces = surfaces
        self.started = started
        self.screen = screen
        self.input = input
        self.log = log
    }

    var encodings: [String] {
        (ycodec_jpeg_available() != 0 ? ["jpeg"] : []) + (ycodec_zlib_available() != 0 ? ["zlib"] : [])
    }

    func start() {
        log("display server: listening on \(listener.address) (encodings: \(encodings.joined(separator: ", ")); "
            + "input: \(input == nil ? "not delivered" : "delivered"))")
        let t = Thread { [self] in acceptLoop() }
        t.name = "display-accept"
        t.start()
    }

    /// The device is going down: clients get a "stopping" status, then the end.
    func stop(message: String) {
        let s = lock.withLock { () -> DisplayClientSession? in
            stopping = true
            stopMessage = message
            return current
        }
        s?.sendStatus(phase: "stopping", message: message)
        s?.close()
        listener.close()
    }

    var isStopping: Bool { lock.withLock { stopping } }
    var uptime: Int { Int(monotonicMilliseconds() - started) }

    private func acceptLoop() {
        while let c = listener.accept() {
            if isStopping { c.close(); break }
            let session = DisplayClientSession(connection: c, server: self)
            let old = lock.withLock { () -> DisplayClientSession? in
                defer { current = session }
                return current
            }
            if let old {
                old.sendNotice("another viewer connected; this one is closed")
                old.close()
            }
            session.start()
        }
    }

    func ended(_ session: DisplayClientSession) {
        lock.withLock { if current === session { current = nil } }
    }

    var hello: DisplayServerHello {
        DisplayServerHello(deviceName: DeviceLayout.deviceName, model: model, pixelWidth: screen.width,
                           pixelHeight: screen.height, scale: screen.scale, encodings: encodings,
                           touch: input?.acceptsTouch ?? false, keyboard: input?.acceptsKeyboard ?? false,
                           buttons: (input?.buttons ?? []).map(\.name), rotation: false)
    }

    /// The presented surface (or, before the first frame, nothing).
    func presentedSurface(_ record: FrameRecord?) -> IOSurfaceInfo? {
        guard let record, let s = surfaces.surface(id: record.surface) else { return nil }
        guard s.bytesPerElement == 4, s.width > 0, s.height > 0,
              UInt64(s.bytesPerRow * (s.height - 1) + s.width * 4) <= s.memory.size else { return nil }
        return s
    }
}

final class DisplayClientSession: @unchecked Sendable {
    let connection: DisplayConnection
    unowned let server: DisplayServer
    private let condition = NSCondition()
    private var settings: DisplayClientHello?
    private var keyframeWanted = true
    private var closed = false
    private var lastInput: UInt32 = 0
    private var inputUntil: UInt64 = 0
    private var noticeSent = false
    private var recordDirty = false
    // Statistics (logged at the end).
    private var framesSent = 0, bytesSent = 0, encodeNanoseconds: UInt64 = 0, scans = 0
    private let connectedAt = monotonicMilliseconds()

    init(connection: DisplayConnection, server: DisplayServer) {
        self.connection = connection
        self.server = server
    }

    func start() {
        server.log("display server: viewer connected")
        do { try connection.send(.hello(server.hello)) } catch { close(); return }
        let receiver = Thread { [self] in receiveLoop() }
        receiver.name = "display-receive"
        receiver.start()
        let sender = Thread { [self] in sendLoop() }
        sender.name = "display-send"
        sender.start()
    }

    var isClosed: Bool { condition.withLock { closed } }

    func close() {
        let first = condition.withLock { () -> Bool in
            defer { closed = true; condition.broadcast() }
            return !closed
        }
        connection.close()
        if first {
            server.input?.reset()
            let seconds = Double(monotonicMilliseconds() - connectedAt) / 1000
            let encodeMs = Double(encodeNanoseconds) / 1e6
            server.log(String(format: "display server: viewer gone after %.0f s: %d frames, %.1f MB, %.1f fps, %.2f MB/s, encode %.1f ms/frame, %d scans",
                              seconds, framesSent, Double(bytesSent) / 1e6, Double(framesSent) / max(seconds, 0.001),
                              Double(bytesSent) / 1e6 / max(seconds, 0.001), framesSent > 0 ? encodeMs / Double(framesSent) : 0, scans))
            server.ended(self)
        }
    }

    func sendStatus(phase: String, message: String? = nil, guestFrames: Int = 0) {
        try? connection.send(.status(DisplayStatus(phase: phase, uptimeMilliseconds: server.uptime, guestFrames: guestFrames, message: message)))
    }

    func sendNotice(_ text: String) { try? connection.send(.notice(text)) }

    /// The frame record was rewritten (FrameRecordWatcher).
    func recordChanged() {
        // A/B diagnostic (YCODE_DISPLAY_AB=1): the watcher is ignored in odd seconds.
        if DisplayClientSession.abTest, (monotonicMilliseconds() / 1000) % 2 == 1 { return }
        condition.withLock { recordDirty = true; condition.broadcast() }
    }

    /// YCODE_DISPLAY_AB=1: alternate the latency features (watcher by the
    /// second, banded encoding by the frame) and mark trace lines with the
    /// arm, for paired measurements (display-stream.md §10).
    static let abTest = ProcessInfo.processInfo.environment["YCODE_DISPLAY_AB"] == "1"

    // MARK: Receiving

    private func receiveLoop() {
        nameThread("display-receive")
        var parser = DisplayMessageParser()
        while let bytes = connection.receive() {
            parser.append(bytes)
            do {
                while let m = try parser.next() { handle(m) }
            } catch {
                server.log("display server: bad message from the viewer: \(error)")
                break
            }
        }
        close()
    }

    private func handle(_ m: DisplayMessage) {
        switch m {
        case .clientHello(var h):
            h.maxFPS = min(120, max(1, h.maxFPS))
            h.quality = min(100, max(1, h.quality))
            h.downscale = min(4, max(1, h.downscale))
            if DisplayEncoding(name: h.encoding) == nil || !server.encodings.contains(h.encoding) {
                h.encoding = server.encodings.first ?? "zlib"
            }
            server.log("display server: viewer \"\(h.client)\": \(h.encoding) q\(h.quality), downscale \(h.downscale), at most \(h.maxFPS) fps")
            condition.withLock {
                settings = h
                keyframeWanted = true
                condition.broadcast()
            }
        case .ping(let token):
            try? connection.send(.pong(token: token, serverNanoseconds: monotonicNanoseconds()))
        case .keyframeRequest:
            condition.withLock { keyframeWanted = true; condition.broadcast() }
        case .screenshotRequest(let token):
            let png = screenshot()
            try? connection.send(.screenshot(token: token, png: png))
        case .rotate:
            sendNotice("rotation is not supported yet")
        case .input(let event):
            let received = monotonicNanoseconds()
            let delivered = server.input?.deliver(event) ?? false
            if let trace = server.trace {
                let kind: String
                switch event {
                case .touch(_, let c): kind = "touch" + (c.first.map { ".\($0.phase)" } ?? "")
                case .key: kind = "key"
                case .button: kind = "button"
                }
                trace.line("input \(event.sequence) \(kind) \(received) \(monotonicNanoseconds()) \(server.hidSequence?() ?? 0)")
            }
            condition.withLock {
                lastInput = event.sequence
                // Look for the guest's answer more often for a moment.
                inputUntil = monotonicMilliseconds() + 500
                condition.broadcast()
            }
            if !delivered && !noticeSent {
                noticeSent = true
                sendNotice(server.input == nil ? "this device takes no input (ycode-simd without the HID bundle)"
                    : "input not delivered: the guest's HID bundle has not registered (yet)")
            }
        default:
            break
        }
    }

    private func screenshot() -> [UInt8] {
        let reader = FrameRecordReader(path: server.statePath)
        guard let record = reader.read(), let snap = server.surfaces.snapshot(surfaceID: record.surface),
              snap.bytesPerElement == 4, snap.width > 0, snap.height > 0 else { return [] }
        let rgba = PNG.rgba(fromBGRA: snap.bytes, width: snap.width, height: snap.height, bytesPerRow: snap.bytesPerRow)
        return CompressedPNG.encode(width: snap.width, height: snap.height, rgba: rgba)
    }

    // MARK: Sending

    private func sendLoop() {
        nameThread("display-send")
        // Wait (briefly) for the client's hello; defaults otherwise.
        let helloDeadline = monotonicMilliseconds() + 2000
        condition.withLock {
            while settings == nil && !closed && monotonicMilliseconds() < helloDeadline {
                _ = condition.wait(until: Date(timeIntervalSinceNow: 0.05))
            }
            if settings == nil { settings = DisplayClientHello(client: "unknown", encoding: server.encodings.first ?? "zlib") }
        }
        let reader = FrameRecordReader(path: server.statePath)
        let watcher = FrameRecordWatcher(path: server.statePath) { [weak self] in self?.recordChanged() }
        defer { watcher?.stop() }
        var mirror: DisplayMirror?
        var encoder: TileEncoder?
        var lastRecord: FrameRecord?
        var phase = ""
        var settleUntil: UInt64 = 0
        var lastScan: UInt64 = 0        // ns
        var lastSent: UInt64 = 0        // ns
        var unscanned = false           // a new frame record not scanned yet
        var nextSafetyScan: UInt64 = 0
        var nextStatus: UInt64 = 0
        var sequence: UInt64 = 0
        while !isClosed {
            let now = monotonicMilliseconds()
            let record = reader.read()
            if let record, record != lastRecord {
                lastRecord = record
                settleUntil = now + 300
                unscanned = true
                server.trace?.line("record \(record.frame) \(monotonicNanoseconds())"
                                   + (Self.abTest ? ((monotonicMilliseconds() / 1000) % 2 == 1 ? " poll" : " watch") : ""))
            }
            let newPhase = server.isStopping ? "stopping" : (record == nil ? "booting" : "live")
            if newPhase != phase || now >= nextStatus {
                phase = newPhase
                sendStatus(phase: phase, guestFrames: Int(record?.frame ?? 0))
                nextStatus = now + (phase == "booting" ? 1000 : 5000)
            }
            let (s, keyframe, inputUntil) = condition.withLock { (settings!, keyframeWanted, self.inputUntil) }
            // Pacing (display-stream.md §4.2): maxFPS limits the frames sent. A
            // new frame record (or a keyframe request) is scanned as soon as
            // that allows; the speculative scans (settling after a frame,
            // after input, the safety net) run at most once per interval and
            // never hold back the scan of a new frame.
            let intervalNs = 1_000_000_000 / UInt64(s.maxFPS)
            let nowNs = monotonicNanoseconds()
            let urgent = keyframe || unscanned
            let speculative = now < settleUntil || now < inputUntil || now >= nextSafetyScan
            let wanted = urgent || speculative
            let allowed = nowNs &- lastSent >= intervalNs && (urgent || nowNs &- lastScan >= intervalNs)
            if wanted, allowed, let surface = server.presentedSurface(record) {
                let enc = DisplayEncoding(name: s.encoding) ?? .zlibBGRA
                if mirror == nil || mirror!.width != surface.width || mirror!.height != surface.height
                    || encoder?.downscale != s.downscale {
                    mirror = DisplayMirror(width: surface.width, height: surface.height, tile: 32 * s.downscale)
                    condition.withLock { keyframeWanted = true }
                }
                if encoder == nil || encoder!.encoding != enc || encoder!.quality != s.quality || encoder!.downscale != s.downscale {
                    encoder = TileEncoder(encoding: enc, quality: s.quality, downscale: s.downscale)
                }
                let full = condition.withLock { () -> Bool in defer { keyframeWanted = false }; return keyframeWanted }
                let inputSeq = condition.withLock { lastInput }
                lastScan = nowNs
                unscanned = false
                if now >= nextSafetyScan { nextSafetyScan = now + 1000 }
                scans += 1
                let t0 = monotonicNanoseconds()
                let rects = mirror!.update(from: UnsafeRawPointer(surface.memory.host), bytesPerRow: surface.bytesPerRow, full: full)
                if !rects.isEmpty {
                    let banded = !Self.abTest || sequence % 2 == 0
                    let tiles = banded ? encoder!.encodeAll(rects, mirror: mirror!)
                        : rects.compactMap { encoder!.encode($0, mirror: mirror!) }
                    let t1 = monotonicNanoseconds()
                    encodeNanoseconds += t1 - t0
                    sequence += 1
                    let f = s.downscale
                    let frame = DisplayFrame(sequence: sequence, guestFrame: record?.frame ?? 0, serverNanoseconds: t1, inputSequence: inputSeq,
                                             width: (surface.width + f - 1) / f, height: (surface.height + f - 1) / f, encoding: enc,
                                             isFull: full, tiles: tiles)
                    let bytes = DisplayMessage.frame(frame).encoded()
                    do { try connection.send(bytes) } catch { break }
                    server.trace?.line("frame \(sequence) \(record?.frame ?? 0) \(t0) \(t1) \(monotonicNanoseconds()) \(bytes.count) \(tiles.count) \(inputSeq)"
                                      + (Self.abTest ? " ab \(banded ? "banded" : "single") \((monotonicMilliseconds() / 1000) % 2 == 1 ? "poll" : "watch")" : ""))
                    lastSent = monotonicNanoseconds()
                    framesSent += 1
                    bytesSent += bytes.count
                }
                continue
            }
            // Idle: poll the frame record every 4 ms (8 ms while nothing moves);
            // the watcher wakes the loop at once when the record changes.
            var pause = now < settleUntil || now < inputUntil || keyframe ? 0.004 : 0.008
            // A scan held back by maxFPS: wait exactly until it is allowed.
            if wanted, !allowed {
                let since = min(nowNs &- lastSent, urgent ? UInt64.max : nowNs &- lastScan)
                if since < intervalNs { pause = min(pause, Double(intervalNs - since) / 1e9) }
            }
            condition.withLock {
                if !closed && !recordDirty { _ = condition.wait(until: Date(timeIntervalSinceNow: pause)) }
                recordDirty = false
            }
        }
        close()
    }
}
#endif

#if os(Linux) && arch(arm64)
/// ExecHost's hook: with `--display-server` in device mode, starts the
/// server and makes SIGTERM, SIGINT, and SIGHUP end the device session
/// (launchd_sim shuts the guest down; launch-sim-control.md §3.1) instead
/// of killing the VMM. A second signal, or a session not bound yet, exits
/// at once (status 128 + signal).
func startDisplayServer(config: ExecConfiguration, surfaces: IOSurfaceHostService?, session: DeviceSession?,
                        hid: HIDHostService?, started: UInt64, guestClock: (() -> UInt64?)? = nil) -> DisplayServer? {
    guard let address = config.options.displayServer else { return nil }
    guard let device = config.device, let surfaces else {
        stderrLine("ycode-simd: --display-server needs --device and the IOSurface service; not started")
        return nil
    }
    let server: DisplayServer
    // The display and touch space are the device type's (ipad.md §6).
    let screen = device.deviceType.screen
    do {
        server = try DisplayServer(address: address, statePath: device.framebufferStatePath, surfaces: surfaces, started: started,
                                   screen: (screen.width, screen.height, screen.scale),
                                   input: hid.map { HIDInputBridge(hid: $0, pointWidth: screen.pointWidth, pointHeight: screen.pointHeight) },
                                   log: { stderrLine("ycode-simd: " + $0) })
        server.model = device.deviceType.modelIdentifier
    } catch {
        stderrLine("ycode-simd: cannot start the display server on \(address): \(error)")
        return nil
    }
    if DeviceLayout.displayTiming {
        server.trace = DisplayTrace(path: device.displayTracePath, guestClock: guestClock)
        server.hidSequence = hid.map { h in { h.lastSequence } }
        server.log("display server: timing trace \(server.trace == nil ? "not available" : device.displayTracePath)")
    }
    server.start()
    // With a stop snapshot (YCODE_SNAPSHOT_STOP_DIR: the launchers' warm
    // boot, snapshot.md §12.2) the signals save the device; the viewer is
    // told that the device is stopping first.
    if let snap = SnapshotSupport.shared, snap.handlesStopSignals {
        snap.beforeStop = { [weak server] in server?.stop(message: "the device is being saved; the next run continues from it") }
        return server
    }
    let signalCount = SignalCounter(0)
    for sig in [SIGTERM, SIGINT, SIGHUP] {
        signal(sig, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
        source.setEventHandler { [weak session, weak server] in
            let n = signalCount.increment()
            guard n == 1, let session, session.isBound else {
                stderrLine("ycode-simd: signal \(sig): exiting now")
                if case .unix(let path) = address { unlink(path) }
                _exit(128 + sig)
            }
            stderrLine("ycode-simd: signal \(sig): ending the device session (again to exit at once)")
            server?.stop(message: "the device is shutting down")
            session.end()
            // launchd_sim normally exits within seconds; do not hang forever.
            DispatchQueue.global().asyncAfter(deadline: .now() + 30) {
                stderrLine("ycode-simd: the guest did not shut down within 30 s; exiting")
                _exit(128 + sig)
            }
        }
        source.resume()
        DisplaySignalSources.keep.append(source)
    }
    return server
}

enum DisplaySignalSources {
    nonisolated(unsafe) static var keep: [any DispatchSourceSignal] = []
}

/// A small counter for the signal handler.
final class SignalCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int
    init(_ value: Int) { self.value = value }
    func increment() -> Int { lock.withLock { value += 1; return value } }
}
#endif
