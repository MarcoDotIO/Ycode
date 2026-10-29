// One live device: its display-stream connection, what the server said
// (hello, status, the panel shown), the newest picture, statistics, and the
// device commands (buttons, rotation, the fold, screenshots, recordings,
// settings commands). Every window that shows the device (the compact
// window, the hub's canvas) observes the same session; it is the input
// handler of each of their screens (display-stream.md §7,
// device-hub.md "Ycode implementation").

#if os(macOS)
import AppKit
import YcodeDeviceModel
import YcodeDisplayStream

/// What changed in a session.
public enum DeviceSessionChange: Sendable, Equatable {
    case hello, phase, displayState, image, notice(String), recording, statistics
}

@MainActor
public protocol DeviceLiveSessionObserver: AnyObject {
    func session(_ s: DeviceLiveSession, changed: DeviceSessionChange)
}

@MainActor
public final class DeviceLiveSession: NSObject, ViewerConnectionDelegate, DeviceInputHandler {
    public let connection: ViewerConnection
    public private(set) var hello: DisplayServerHello?
    public private(set) var panelState: DisplayPanelState?
    /// connecting, disconnected, booting, live, stopping.
    public private(set) var phase = "connecting"
    public private(set) var phaseDetail: String?
    public private(set) var uptimeMilliseconds = 0
    public private(set) var image: CGImage?
    /// The device type (from the hello; `knownSpec` until one arrives).
    public private(set) var spec: DeviceFrameSpec
    /// The window title (the device's name) and subtitle (its OS); the IDE
    /// sets the names it lists, the viewer takes the hello's.
    public var displayName: String?
    public var osTitle: String?
    public var log: (String) -> Void = { _ in }
    public var onFrame: ((DisplayFrame) -> Void)?

    // Statistics (the debug status line).
    private var frameTimes: [UInt64] = []
    private var lastBytes = 0
    private var lastStatsTime = nowNanoseconds()
    public private(set) var bandwidth: Double = 0
    public private(set) var rtt: Double?
    private var probes: [(seq: UInt32, sent: UInt64, label: String)] = []
    public private(set) var latencies: [(label: String, ms: Double)] = []
    public private(set) var lastLatency: Double?
    private var screenshotWaiters: [UInt32: ([UInt8]) -> Void] = [:]
    private var nextScreenshot: UInt32 = 1
    private var timer: Timer?
    private var observers: [WeakObserver] = []
    public private(set) var recorder: ScreenRecorder?

    public init(connection: ViewerConnection, spec: DeviceFrameSpec? = nil) {
        self.connection = connection
        self.spec = spec ?? .iPhoneDuo
        super.init()
        connection.delegate = self
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
    }

    public func start() { connection.start() }

    /// Ends the connection (and a recording).
    public func close() {
        stopRecording()
        timer?.invalidate()
        connection.stop()
    }

    // MARK: Observers

    private final class WeakObserver {
        weak var value: DeviceLiveSessionObserver?
        init(_ v: DeviceLiveSessionObserver) { value = v }
    }

    public func addObserver(_ o: DeviceLiveSessionObserver) {
        observers.removeAll { $0.value == nil || $0.value === o }
        observers.append(WeakObserver(o))
    }

    public func removeObserver(_ o: DeviceLiveSessionObserver) { observers.removeAll { $0.value == nil || $0.value === o } }

    private func notify(_ c: DeviceSessionChange) {
        for o in observers.compactMap(\.value) { o.session(self, changed: c) }
    }

    // MARK: State

    public var isLive: Bool { phase == "live" }
    public var hasImage: Bool { image != nil }
    public var isFoldable: Bool { hello?.foldable == true || (hello == nil && spec.isFoldable) }
    /// The server turns the device (display-stream.md §11: foldables today).
    public var canRotate: Bool { hello?.rotation == true }
    public var title: String { displayName ?? (spec.typeID == "unknown" ? hello?.deviceName ?? "Device" : spec.name) }
    public var subtitle: String { osTitle ?? hello?.osVersion ?? "" }
    /// The panel shown (0: display 1 / the cover, 1: the inner panel).
    public var panelIndex: Int { spec.panelIndex(named: panelState?.display) }
    public var orientation: DeviceOrientation { DeviceOrientation(streamName: panelState?.orientation ?? hello?.orientation) }
    public var posture: DevicePosture? {
        guard isFoldable else { return nil }
        if let p = panelState.flatMap({ DevicePosture(rawValue: $0.posture) }) { return p }
        return .closed
    }
    /// The angle the hinge is at or moving to.
    public var hingeTarget: Int? { panelState.map { $0.targetAngle ?? $0.hingeAngle } }

    /// The shown picture's size in points (touch space as shown).
    public var shownPointSize: CGSize {
        if let p = panelState {
            let s = p.shownPointSize
            return CGSize(width: s.width, height: s.height)
        }
        if let h = hello { return CGSize(width: h.pointWidth, height: h.pointHeight) }
        return spec.panels[0].uprightPointSize
    }

    /// The frame for the current panel, orientation and pose.
    public func frameGeometry(bezels: Bool) -> DeviceFrameGeometry {
        DeviceFrameGeometry(spec: spec, panelIndex: panelIndex, clockwiseQuarterTurns: orientation.clockwiseQuarterTurns,
                            posture: posture, bezels: bezels)
    }

    /// The canvas's problem text while there is no picture (§4.1).
    public var problemText: String? {
        switch phase {
        case "connecting": phaseDetail == nil ? "Connecting display" : "Connecting display (\(phaseDetail!))"
        case "disconnected": "The device is not running or the connection dropped; reconnecting"
        case "booting": "Starting… \(uptimeMilliseconds / 1000) s"
        case "stopping": "The device is shutting down"
        case "live": hasImage ? nil : "Waiting for the first frame"
        default: phase
        }
    }

    /// The debug status line (More Actions ▸ Show Frame Rate): phase, frame
    /// rate, bandwidth, input latency, round trip.
    public var statisticsText: String {
        let now = nowNanoseconds()
        let fps = frameTimes.filter { now - $0 < 1_000_000_000 }.count
        var t = "\(phase) · \(fps) fps · " + String(format: "%.0f KB/s", bandwidth / 1000)
        if let lastLatency { t += String(format: " · input→screen %.0f ms", lastLatency) }
        if let rtt { t += String(format: " · rtt %.0f ms", rtt) }
        if let p = panelState, isFoldable { t += " · \(p.display) hinge \(p.hingeAngle)°" }
        if let h = hello, !h.touch { t += " · input not delivered" }
        return t
    }

    private func tick() {
        let now = nowNanoseconds()
        let bytes = connection.stats.bytes
        bandwidth = Double(bytes - lastBytes) / (Double(now - lastStatsTime) / 1e9)
        lastBytes = bytes
        lastStatsTime = now
        frameTimes.removeAll { now - $0 > 1_000_000_000 }
        probes.removeAll { now - $0.sent > 5_000_000_000 }
        if phase == "live" || phase == "booting" { connection.ping() }
        notify(.statistics)
    }

    // MARK: ViewerConnectionDelegate

    public func connection(_ c: ViewerConnection, phase: String, detail: String?) {
        self.phase = phase
        phaseDetail = detail
        if phase == "disconnected" { image = nil }
        notify(.phase)
    }

    public func connection(_ c: ViewerConnection, hello: DisplayServerHello) {
        self.hello = hello
        log("hello: \(hello.deviceName) \(hello.model) \(hello.pixelWidth)x\(hello.pixelHeight) @\(hello.scale), encodings \(hello.encodings), "
            + "touch \(hello.touch), keyboard \(hello.keyboard), buttons \(hello.buttons)"
            + (hello.deviceType.map { ", type \($0)" } ?? "") + (hello.osVersion.map { ", \($0)" } ?? ""))
        spec = DeviceFrameSpec.matching(typeID: hello.deviceType, model: hello.model, pixelWidth: hello.pixelWidth,
                                        pixelHeight: hello.pixelHeight, scale: hello.scale)
        if hello.foldable != true { panelState = nil }
        notify(.hello)
    }

    public func connection(_ c: ViewerConnection, displayState: DisplayPanelState) {
        let switched = panelState?.display != displayState.display || panelState?.rotation != displayState.rotation
        panelState = displayState
        if switched {
            log("display: \(displayState.display) turned \(displayState.rotation)° (hinge \(displayState.hingeAngle)°, \(displayState.posture), \(displayState.orientation))")
        }
        notify(.displayState)
    }

    public func connection(_ c: ViewerConnection, status: DisplayStatus) {
        if phase != status.phase { log("phase: \(status.phase) at \(status.uptimeMilliseconds) ms" + (status.message.map { " (\($0))" } ?? "")) }
        phase = status.phase
        uptimeMilliseconds = status.uptimeMilliseconds
        notify(.phase)
    }

    public func connection(_ c: ViewerConnection, image: CGImage, frame: DisplayFrame, receivedAt: UInt64) {
        let first = self.image == nil
        self.image = image
        if first { log("first frame: \(frame.width)x\(frame.height), \(frame.byteCount) bytes") }
        frameTimes.append(nowNanoseconds())
        if frame.inputSequence > 0 {
            let shown = nowNanoseconds()
            while let p = probes.first, p.seq <= frame.inputSequence {
                probes.removeFirst()
                let ms = Double(receivedAt - p.sent) / 1e6
                lastLatency = ms
                latencies.append((p.label, ms))
                log(String(format: "latency: %@ (input #%u) → first change %.0f ms (shown %.0f ms)", p.label, p.seq, ms,
                           Double(shown - p.sent) / 1e6))
            }
        }
        recorder?.append(image)
        notify(.image)
        if first { notify(.phase) }
        onFrame?(frame)
    }

    public func connection(_ c: ViewerConnection, notice: String) {
        log("notice: \(notice)")
        notify(.notice(notice))
    }

    public func connection(_ c: ViewerConnection, screenshot png: [UInt8], token: UInt32) {
        screenshotWaiters.removeValue(forKey: token)?(png)
    }

    public func connection(_ c: ViewerConnection, pongToken token: UInt64, rttMilliseconds: Double) { rtt = rttMilliseconds }

    // MARK: Input (DeviceInputHandler)

    private func probe(_ seq: UInt32, _ label: String?) {
        guard seq != 0, let label else { return }
        probes.append((seq, nowNanoseconds(), label))
    }

    public func sendTouch(_ contacts: [TouchContact], label: String?) {
        // A view's points are the shown (turned) picture's; touches are in
        // the panel's own points (display-stream.md §5.1).
        var contacts = contacts
        if let p = panelState, p.quarterTurns != 0 {
            contacts = contacts.map { c in
                let n = p.nativePoint(shownX: Double(c.x), shownY: Double(c.y))
                return TouchContact(finger: c.finger, phase: c.phase, x: Float(n.x), y: Float(n.y))
            }
        }
        probe(connection.sendInput { .touch(sequence: $0, contacts: contacts) }, label)
    }

    public func sendKey(usage: UInt16, down: Bool, label: String?) {
        let seq = connection.sendInput { .key(sequence: $0, down: down, usagePage: KeyMap.keyboardPage, usage: usage) }
        probe(seq, down ? label : nil)
    }

    /// A button: down, then up 100 ms later.
    public func press(_ button: DisplayButton) {
        buttonDown(button)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [self] in buttonUp(button) }
    }

    /// A frame button held with the mouse: down now, up when released.
    public func buttonDown(_ button: DisplayButton) {
        probe(connection.sendInput { .button(sequence: $0, button: button, down: true) }, button.name)
    }

    public func buttonUp(_ button: DisplayButton) {
        connection.sendInput { .button(sequence: $0, button: button, down: false) }
    }

    /// Controls ▸ App Switcher: Home pressed twice (Ycode decision).
    public func appSwitcher() {
        press(.home)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [self] in press(.home) }
    }

    /// The frame button → the display stream's button (Ycode decision: the
    /// side and top buttons are Sleep/Wake (lock), the action button the
    /// side usage).
    public static func displayButton(for kind: DeviceFrameGeometry.ButtonKind) -> DisplayButton {
        switch kind {
        case .side, .top: .lock
        case .volumeUp: .volumeUp
        case .volumeDown: .volumeDown
        case .action: .side
        }
    }

    // MARK: Rotation and the fold

    /// Rotate (click: left; Option-click: right).
    public func rotate(left: Bool) { setOrientation(orientation.rotated(left: left)) }

    public func setOrientation(_ o: DeviceOrientation) {
        guard canRotate else { notify(.notice("This device does not rotate")); return }
        connection.send(.rotate(orientation: o.streamCode))
    }

    /// Moves the hinge to `angle` (a sweep; foldable.md §8.3).
    public func fold(to angle: Int) {
        guard isFoldable else { return }
        connection.send(.fold(angle: UInt16(min(180, max(0, angle))), instant: false))
    }

    public func refreshDisplay() { connection.send(.keyframeRequest) }

    // MARK: Screenshots

    /// A full-resolution PNG from the server (the shown picture when that fails).
    public func requestScreenshot(_ done: @escaping ([UInt8]?) -> Void) {
        let token = nextScreenshot
        nextScreenshot += 1
        var answered = false
        screenshotWaiters[token] = { png in answered = true; done(png.isEmpty ? self.shownPNG() : png) }
        if !connection.send(.screenshotRequest(token: token)) {
            screenshotWaiters.removeValue(forKey: token)
            done(shownPNG())
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [self] in
            if !answered, screenshotWaiters.removeValue(forKey: token) != nil { done(shownPNG()) }
        }
    }

    public func shownPNG() -> [UInt8]? {
        guard let image else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]).map { [UInt8]($0) }
    }

    /// Where screenshots and recordings go: the user's screenshot location
    /// when one is set (the system's screen-capture preference), else the
    /// Desktop (§4.4); `YCODE_DEVICE_CAPTURE_DIR` overrides both (tests).
    public static var captureDirectory: URL {
        // Test runs keep their captures out of the Desktop.
        if let d = ProcessInfo.processInfo.environment["YCODE_DEVICE_CAPTURE_DIR"], !d.isEmpty {
            return URL(fileURLWithPath: d, isDirectory: true)
        }
        if let loc = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location"), !loc.isEmpty {
            let url = URL(fileURLWithPath: (loc as NSString).expandingTildeInPath, isDirectory: true)
            var dir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &dir), dir.boolValue { return url }
        }
        return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSHomeDirectory())
    }

    /// Controls ▸ Screenshot: saves the PNG and calls back with its URL or an error.
    public func saveScreenshot(_ done: @escaping (Result<URL, Error>) -> Void) {
        requestScreenshot { [self] png in
            guard let png else { done(.failure(CaptureError("no picture yet"))); return }
            let url = Self.captureDirectory.appendingPathComponent(DeviceCaptureNames.screenshot(device: title, at: Date()))
            do {
                try Data(png).write(to: url)
                log("screenshot: \(url.path)")
                done(.success(url))
            } catch {
                done(.failure(error))
            }
        }
    }

    // MARK: Recording

    public var isRecording: Bool { recorder != nil }

    /// Controls ▸ Record Screen: the shown pictures become a movie.
    public func startRecording() throws {
        guard recorder == nil else { return }
        let url = Self.captureDirectory.appendingPathComponent(DeviceCaptureNames.recording(device: title, at: Date()))
        let r = try ScreenRecorder(url: url)
        recorder = r
        if let image { r.append(image) }
        log("recording: \(url.path)")
        notify(.recording)
    }

    /// Controls ▸ Stop Recording; `done` gets the movie's URL when it is written.
    public func stopRecording(_ done: (@MainActor @Sendable (URL?) -> Void)? = nil) {
        guard let r = recorder else { done?(nil); return }
        recorder = nil
        notify(.recording)
        r.finish { url in
            DispatchQueue.main.async { MainActor.assumeIsolated { done?(url) } }
        }
    }

    // MARK: Commands

    /// A device command (the settings features; display-stream.md 0x90).
    public func sendCommand(_ text: String, reply: @escaping @MainActor @Sendable (String) -> Void) {
        connection.sendCommand(text, reply: reply)
    }
}

public struct CaptureError: Error, CustomStringConvertible, LocalizedError {
    public let description: String
    public init(_ d: String) { description = d }
    public var errorDescription: String? { description }
}
#endif
