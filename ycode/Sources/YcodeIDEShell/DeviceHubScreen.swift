import Foundation
import Observation
import YcodeDeviceModel
import YcodeDisplayStream
import YcodeRemoteViewer

/// One running device's live screen in the Linux IDE's Device Hub
/// (`device-hub.md` §4, "Ycode decisions (2026-11-17)"): the display-stream
/// client (`RemoteDeviceSession`, the one the device window uses), drained
/// on the main actor whenever the connection has news, and each new picture
/// sampled to the size the canvas shows it at, as RGBA rows for the
/// toolkit's image. The canvas's pointer goes to the session in canvas
/// points (the session's "window units": the canvas is its window); the
/// controls (Home, Lock, Rotate, Screenshot) and the settings commands go
/// through the stream.
@MainActor
@Observable
public final class DeviceHubScreen {
    @ObservationIgnored public let session: RemoteDeviceSession
    public let deviceID: String
    /// The latest picture, sampled for the canvas (nil: none yet).
    public private(set) var picture: DeviceScreenPicture?
    /// Counts the pictures (the canvas redraws on a change).
    public private(set) var frames = 0
    /// What the session says while there is no picture ("Connecting display", "Starting... 12 s").
    public private(set) var problem: String?
    /// The device's frame as the session lays it out in the canvas.
    public private(set) var layout: ViewerLayout
    public private(set) var phase = "connecting"
    public private(set) var isTakenOver = false
    /// The server's hello arrived: the device's type, OS and controls are known.
    public private(set) var hasHello = false
    @ObservationIgnored private var pumpScheduled = false
    @ObservationIgnored private var lastSample: UInt64 = 0
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var lastTick: UInt64 = 0
    @ObservationIgnored private var sampledRotation = 0
    /// Where screenshots go (`YCODE_DEVICE_CAPTURE_DIR`, else ~/Pictures, as the device window).
    @ObservationIgnored public var captureDirectory: URL
    /// The longest gap between samples while frames arrive (a 30-frame-a-second canvas).
    public static let sampleInterval: UInt64 = 33_000_000

    public init(deviceID: String, connect: @escaping @Sendable () throws -> DisplayTransport, spec: DeviceFrameSpec,
                environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.deviceID = deviceID
        var settings = DisplayClientHello(client: "ycode-ide-device-hub", maxFPS: 30, encoding: "jpeg", quality: 80, downscale: 1)
        // The best this host decodes that the server offers (display-stream.md §14).
        settings.encoding = StreamCanvas.decodableEncodings.first ?? "zlib"
        settings.encodings = StreamCanvas.decodableEncodings
        let client = DisplayStreamClient(settings: settings, connect: connect)
        session = RemoteDeviceSession(client: client)
        session.hubFit = true
        session.preview(spec: spec)
        layout = session.layout
        captureDirectory = URL(fileURLWithPath: environment["YCODE_DEVICE_CAPTURE_DIR"] ?? (NSHomeDirectory() + "/Pictures"), isDirectory: true)
        session.wake = { [weak self] in
            Task { @MainActor in self?.scheduleDrain() }
        }
    }

    /// Connects (the session reconnects every second while the device boots).
    public func start() {
        session.start()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                self?.pump()
            }
        }
    }

    public func stop() {
        ticker?.cancel()
        ticker = nil
        session.stop()
    }

    // MARK: Canvas geometry

    /// The canvas's size in points and its pixels per point: the device is
    /// laid out in it by the macOS hub's Zoom to Fit rule (§15.2).
    public func setCanvas(width: Double, height: Double, pixelDensity: Double) {
        guard width != session.windowWidth || height != session.windowHeight || pixelDensity != session.pixelDensity else { return }
        session.windowWidth = width
        session.windowHeight = height
        session.pixelDensity = pixelDensity
        refreshLayout()
        sample()
    }

    /// Whether the layout changed (a turn, the other panel, a new canvas size).
    @discardableResult
    private func refreshLayout() -> Bool {
        let l = session.layout
        guard l != layout else { return false }
        layout = l
        return true
    }

    // MARK: Draining

    private func scheduleDrain() {
        guard !pumpScheduled else { return }
        pumpScheduled = true
        let wait = Self.sampleInterval > viewerNanoseconds() &- lastSample ? Self.sampleInterval - (viewerNanoseconds() &- lastSample) : 0
        Task { @MainActor [weak self] in
            if wait > 0 { try? await Task.sleep(nanoseconds: wait) }
            self?.pumpScheduled = false
            self?.pump()
        }
    }

    /// Applies what arrived: the hello, the state, a new picture.
    public func pump() {
        let image = session.drain()
        let now = viewerNanoseconds()
        if now &- lastTick >= 1_000_000_000 {
            lastTick = now
            session.tick(now: now)
        }
        session.idle(now: Double(now) / 1e9)
        hasHello = session.hello != nil
        if phase != session.phase { phase = session.phase }
        if isTakenOver != session.isTakenOver { isTakenOver = session.isTakenOver }
        let p = session.hasImage ? session.startingText() : session.problemText
        if problem != p { problem = p }
        // A turn can arrive after the last picture: the picture is sampled
        // again for the new layout and rotation, not only for a new frame.
        let turned = session.imageRotation != sampledRotation
        if refreshLayout() || image || turned { sample() }
    }

    /// Samples the stream's picture for the canvas.
    private func sample() {
        guard session.hasImage, let canvas = session.client.currentCanvas else { return }
        let screen = layout.screen
        // The picture as shown (after a turn), in output pixels.
        let outW = max(1, Int((screen.width * layout.pixelDensity).rounded())), outH = max(1, Int((screen.height * layout.pixelDensity).rounded()))
        let rotation = session.imageRotation
        let pic = canvas.withPixels { base, rowBytes, _ in
            DeviceScreenPicture.sample(bgrx: base, rowBytes: rowBytes, width: canvas.width, height: canvas.height, rotation: rotation,
                                       width: outW, height: outH)
        }
        picture = pic
        sampledRotation = rotation
        frames &+= 1
        lastSample = viewerNanoseconds()
        if let f = session.lastFrame { session.presented(sequence: f.frame.sequence) }
    }

    // MARK: Input (canvas points)

    public func pointerDown(x: Double, y: Double) {
        if session.isTakenOver { session.takeBack(); return }
        session.pointerDown(x: x, y: y, multiTouch: false, shift: false)
    }
    public func pointerMoved(x: Double, y: Double) { session.pointerMoved(x: x, y: y, multiTouch: false) }
    public func pointerUp(x: Double, y: Double) { session.pointerUp(x: x, y: y) }

    /// Another viewer (the device window of a run) has the display: take it back.
    public func takeBack() { session.takeBack() }

    // MARK: Controls

    public var isLive: Bool { session.phase == "live" }
    public var canRotate: Bool { session.canRotate }

    public func press(_ b: DisplayButton) { session.press(b) }
    public func rotate(left: Bool) { session.rotate(left: left) }

    /// Screenshot: the server's full-resolution PNG, saved as the device
    /// window saves it; `done` gets the file (nil: it failed).
    public func saveScreenshot(name: String, done: @escaping @MainActor (URL?) -> Void) {
        let dir = captureDirectory
        let url = dir.appendingPathComponent(DeviceCaptureNames.screenshot(device: name, at: Date()))
        session.requestScreenshot { png in
            var saved: URL?
            if !png.isEmpty {
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                if (try? Data(png).write(to: url)) != nil { saved = url }
            }
            let result = saved
            Task { @MainActor in done(result) }
        }
    }

    /// A control-socket command over the stream (`ui appearance dark`, `settings`).
    public func command(_ words: [String]) async -> String {
        await withCheckedContinuation { (k: CheckedContinuation<String, Never>) in
            session.sendCommand(words.joined(separator: " ")) { reply in k.resume(returning: reply) }
        }
    }
}

/// A device screen's picture for the canvas: RGBA rows (opaque), sampled
/// from the stream's BGRX picture and turned as the panel shows it.
public struct DeviceScreenPicture: Equatable, Sendable {
    public var width: Int
    public var height: Int
    public var rgba: [UInt8]

    public init(width: Int, height: Int, rgba: [UInt8]) {
        (self.width, self.height, self.rgba) = (width, height, rgba)
    }

    /// Samples a BGRX picture (`width` × `height`, `rowBytes` a row) into
    /// `outWidth` × `outHeight` RGBA, turned `rotation` degrees clockwise,
    /// each output pixel the mean of a 2 × 2 block where the source is at
    /// least twice as large (else the nearest pixel).
    public static func sample(bgrx base: UnsafeRawPointer, rowBytes: Int, width: Int, height: Int, rotation: Int,
                              width outW: Int, height outH: Int) -> DeviceScreenPicture {
        let r = ((rotation % 360) + 360) % 360
        let turned = r == 90 || r == 270
        // The source size as shown.
        let shownW = turned ? height : width, shownH = turned ? width : height
        var out = [UInt8](repeating: 255, count: outW * outH * 4)
        let src = base.assumingMemoryBound(to: UInt8.self)
        let sx = Double(shownW) / Double(outW), sy = Double(shownH) / Double(outH)
        let box = sx >= 2 && sy >= 2
        // Shown (u, v) → source (x, y).
        @inline(__always) func source(_ u: Int, _ v: Int) -> (Int, Int) {
            switch r {
            case 90: (v, height - 1 - u)
            case 180: (width - 1 - u, height - 1 - v)
            case 270: (width - 1 - v, u)
            default: (u, v)
            }
        }
        out.withUnsafeMutableBufferPointer { o in
            var i = 0
            for oy in 0..<outH {
                let v0 = min(shownH - 1, Int((Double(oy) + 0.5) * sy - (box ? 0.5 : 0)))
                let v1 = min(shownH - 1, v0 + 1)
                for ox in 0..<outW {
                    let u0 = min(shownW - 1, Int((Double(ox) + 0.5) * sx - (box ? 0.5 : 0)))
                    if box {
                        let u1 = min(shownW - 1, u0 + 1)
                        var b = 0, g = 0, rr = 0
                        for (u, v) in [(u0, v0), (u1, v0), (u0, v1), (u1, v1)] {
                            let (x, y) = source(u, v)
                            let p = y * rowBytes + x * 4
                            b += Int(src[p]); g += Int(src[p + 1]); rr += Int(src[p + 2])
                        }
                        o[i] = UInt8(rr >> 2); o[i + 1] = UInt8(g >> 2); o[i + 2] = UInt8(b >> 2)
                    } else {
                        let (x, y) = source(u0, v0)
                        let p = y * rowBytes + x * 4
                        o[i] = src[p + 2]; o[i + 1] = src[p + 1]; o[i + 2] = src[p]
                    }
                    i += 4
                }
            }
        }
        return DeviceScreenPicture(width: outW, height: outH, rgba: out)
    }
}
