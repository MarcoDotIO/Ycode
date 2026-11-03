// One device on a portable viewer (display-stream.md §13): the display
// stream client, what the server said, the device's frame and its layout
// in the window, the touch state, the device commands (buttons, rotation,
// screenshots), and the measurements of every frame shown (§12). No window
// toolkit: the Linux window (YcodeRemoteViewerSDL) and the IDE's canvas
// draw from it and feed it pointer and key events in window units.
// Thread-safe: the connection thread posts events, the front end's thread
// drains them with `drain()` and calls everything else.

import Foundation
import YcodeDeviceModel
import YcodeDisplayStream

/// The stage times of one frame, all on the client's clock (ns; 0 unknown).
public struct FrameStages: Sendable, Equatable {
    public var sequence: UInt64
    public var guestFrame: UInt64
    public var bytes: Int
    public var inputSequence: UInt32
    /// Server stages mapped through the clock estimate.
    public var recordSeen: UInt64 = 0, captureStart: UInt64 = 0, encodeEnd: UInt64 = 0, sendEnd: UInt64 = 0
    /// Client stages.
    public var received: UInt64, decoded: UInt64, presented: UInt64 = 0
}

public final class RemoteDeviceSession: @unchecked Sendable {
    public let client: DisplayStreamClient
    /// Called from any thread when there is something to drain (wake the front end).
    public var wake: @Sendable () -> Void = {}
    public var log: @Sendable (String) -> Void = { _ in }

    private let lock = NSLock()
    private var events: [DisplayClientEvent] = []
    private var actions: [@Sendable () -> Void] = []

    // State (front end thread, under the lock where the script reads it).
    public private(set) var hello: DisplayServerHello?
    public private(set) var phase = "connecting"
    public private(set) var phaseDetail: String?
    public private(set) var uptimeMilliseconds = 0
    public private(set) var panel: DisplayPanelState?
    public private(set) var spec: DeviceFrameSpec = .iPhone18Pro
    public private(set) var notice: (text: String, until: Double)?
    public var scaleMode: ViewerScaleMode = .fit
    public var bezels = true
    /// Window size (units) and output pixels per unit, set by the front end.
    public var windowWidth: Double = 480, windowHeight: Double = 900, pixelDensity: Double = 1
    public var multiTouchHover: ViewPoint?
    private var mapper = TouchMapper(viewWidth: 1, viewHeight: 1, pointWidth: 1, pointHeight: 1)
    private var heldButton: DisplayButton?
    private var pressedKeys = Set<UInt16>()
    /// visionOS (visionos.md "Ycode implementation"): the camera and the
    /// hands, and the pointer at the start of a mouse-look drag (Ctrl-drag).
    public private(set) var spatial = SpatialInteraction()
    private var spatialLook: (x: Double, y: Double)?

    // Measurements.
    public private(set) var lastFrame: ReceivedFrame?
    public private(set) var hasImage = false
    private var stagesBySequence: [UInt64: FrameStages] = [:]
    public private(set) var shown: [FrameStages] = []
    public private(set) var latencies: [(label: String, sequence: UInt32, ms: Double)] = []
    /// Input → the frame that includes it presented (glass-to-glass at this end).
    public private(set) var presentLatencies: [(label: String, ms: Double)] = []
    private var pendingProbes: [(seq: UInt32, sent: UInt64, label: String)] = []
    public private(set) var rttMilliseconds: Double?
    private var frameTimes: [UInt64] = []
    private var bytesAtTick = 0, tickAt = viewerNanoseconds()
    public private(set) var bandwidth: Double = 0
    private var screenshotWaiters: [UInt32: @Sendable ([UInt8]) -> Void] = [:]
    private var commandWaiters: [UInt32: @Sendable (String) -> Void] = [:]
    /// The front end's frame callback (scripts count frames).
    public var onFrame: (@Sendable (ReceivedFrame) -> Void)?

    /// The device's sound, when the viewer plays it (§15).
    public private(set) var audio: AudioPlayer?

    public init(client: DisplayStreamClient, audio: AudioPlayer? = nil) {
        self.client = client
        self.audio = audio
        client.onEvent = { [weak self] e in self?.post(e) }
        if let audio {
            client.onAudio = { [weak client] a, arrival in
                audio.receive(a, arrival: arrival, clientPlay: client?.clock.clientTime(server: a.playTime))
            }
        }
    }

    public func start() { client.start() }
    public func stop() { client.stop() }
    /// Another viewer (the headset) has the display (display-stream.md §1.1).
    public var isTakenOver: Bool { phase == DisplayNotice.takenOverPhase }
    /// Connects again, taking the display back (a click on the screen while taken over).
    public func takeBack() { client.takeBack() }

    /// Runs `body` on the front end's thread at its next drain (scripts and
    /// other threads go through this; everything else is not locked).
    public func perform(_ body: @escaping @Sendable () -> Void) {
        lock.withLock { actions.append(body) }
        wake()
    }

    private func post(_ e: DisplayClientEvent) {
        if case .frame(let f) = e { onFrame?(f) }
        lock.withLock { events.append(e) }
        wake()
    }

    // MARK: Draining (front end thread)

    /// Applies the events that arrived; returns whether a new image is in the canvas.
    @discardableResult
    public func drain(now: UInt64 = viewerNanoseconds()) -> Bool {
        let (batch, work) = lock.withLock { () -> ([DisplayClientEvent], [@Sendable () -> Void]) in
            defer { events.removeAll(); actions.removeAll() }
            return (events, actions)
        }
        var image = false
        for e in batch {
            switch e {
            case .phase(let p, let d):
                phase = p
                phaseDetail = d
                if p == "disconnected" { hasImage = false }
            case .hello(let h):
                hello = h
                spec = DeviceFrameSpec.matching(typeID: h.deviceType, model: h.model, pixelWidth: h.pixelWidth, pixelHeight: h.pixelHeight, scale: h.scale)
                if h.foldable != true { panel = nil }
                log("hello: \(h.deviceName) \(h.model) \(h.pixelWidth)x\(h.pixelHeight) @\(h.scale), encodings \(h.encodings), touch \(h.touch), keyboard \(h.keyboard), buttons \(h.buttons)"
                    + (h.deviceType.map { ", type \($0)" } ?? "") + (h.osVersion.map { ", \($0)" } ?? ""))
            case .status(let s):
                if phase != s.phase { log("phase: \(s.phase) at \(s.uptimeMilliseconds) ms" + (s.message.map { " (\($0))" } ?? "")) }
                phase = s.phase
                uptimeMilliseconds = s.uptimeMilliseconds
            case .displayState(let st):
                panel = st
            case .frame(let f):
                if !hasImage { log("first frame: \(f.frame.width)x\(f.frame.height), \(f.frame.bytes) bytes, \(f.frame.encoding.name)") }
                hasImage = true
                image = true
                lastFrame = f
                frameTimes.append(f.decodedAt)
                var st = FrameStages(sequence: f.frame.sequence, guestFrame: f.frame.guestFrame, bytes: f.frame.bytes,
                                     inputSequence: f.frame.inputSequence, received: f.receivedAt, decoded: f.decodedAt)
                if let t = client.takeTiming(sequence: f.frame.sequence) { fill(&st, t) }
                stagesBySequence[f.frame.sequence] = st
            case .timing(let t):
                // A timing that arrived after its frame was handed over.
                if var st = stagesBySequence[t.sequence], st.recordSeen == 0 && st.captureStart == 0 {
                    fill(&st, t)
                    stagesBySequence[t.sequence] = st
                }
            case .inset:
                break   // the headset viewer's foveated streaming only
            case .notice(let text):
                log("notice: \(text)")
                notice = (text, Double(now) / 1e9 + 4)
            case .screenshot(let token, let png):
                screenshotWaiters.removeValue(forKey: token)?(png)
            case .commandReply(let token, let text):
                commandWaiters.removeValue(forKey: token)?(text)
            case .latency(let label, let seq, let ms):
                latencies.append((label, seq, ms))
                log(String(format: "latency: %@ (input #%u) → first change received %.1f ms", label, seq, ms))
            case .pong(let rtt):
                rttMilliseconds = rtt
            }
        }
        if stagesBySequence.count > 512 { stagesBySequence.removeAll() }
        for w in work { w() }
        return image
    }

    private func fill(_ st: inout FrameStages, _ t: DisplayFrameTiming) {
        let c = client.clock
        func map(_ v: UInt64) -> UInt64 { v == 0 ? 0 : (c.clientTime(server: v) ?? 0) }
        st.recordSeen = map(t.recordSeen)
        st.captureStart = map(t.captureStart)
        st.encodeEnd = map(t.encodeEnd)
        st.sendEnd = map(t.sendEnd)
    }

    /// When on, the mean brightness (0–255) of every presented image is kept
    /// with its presented time (scripts' av-probe; costs a 64 × 48 sampling per frame).
    public var tracksBrightness = false
    public private(set) var brightness: [(at: UInt64, mean: Double)] = []

    /// The front end presented the image of frame `sequence` at `at` (ns).
    public func presented(sequence: UInt64, at: UInt64 = viewerNanoseconds()) {
        if tracksBrightness, let s = client.currentCanvas?.greySamples() {
            brightness.append((at, Double(s.reduce(0) { $0 + Int($1) }) / Double(max(1, s.count))))
            if brightness.count > 5000 { brightness.removeFirst(2500) }
        }
        guard var st = stagesBySequence.removeValue(forKey: sequence) else { return }
        // Frames decoded but replaced before presenting were never shown.
        for k in stagesBySequence.keys where k < sequence { stagesBySequence.removeValue(forKey: k) }
        st.presented = at
        shown.append(st)
        if shown.count > 20000 { shown.removeFirst(shown.count - 20000) }
        if st.inputSequence > 0 {
            while let p = pendingProbes.first, p.seq <= st.inputSequence {
                pendingProbes.removeFirst()
                let ms = Double(at - p.sent) / 1e6
                presentLatencies.append((p.label, ms))
                log(String(format: "latency: %@ (input #%u) → presented %.1f ms", p.label, p.seq, ms))
            }
        }
    }

    /// Once a second: bandwidth, frame rate, a ping (clock and round trip).
    public func tick(now: UInt64 = viewerNanoseconds()) {
        let bytes = client.statistics.bytes
        bandwidth = Double(bytes - bytesAtTick) / max(Double(now - tickAt) / 1e9, 0.001)
        bytesAtTick = bytes
        tickAt = now
        frameTimes.removeAll { now - $0 > 1_000_000_000 }
        pendingProbes.removeAll { now - $0.sent > 10_000_000_000 }
        if phase == "live" || phase == "booting" { client.ping() }
        if let n = notice, Double(now) / 1e9 > n.until { notice = nil }
    }

    public var framesPerSecond: Int { frameTimes.count }

    // MARK: Geometry

    public var orientation: DeviceOrientation { DeviceOrientation(streamName: panel?.orientation ?? hello?.orientation) }
    public var panelIndex: Int { spec.panelIndex(named: panel?.display) }

    public var geometry: DeviceFrameGeometry {
        let posture: DevicePosture? = spec.isFoldable ? (panel.flatMap { DevicePosture(rawValue: $0.posture) } ?? .closed) : nil
        return DeviceFrameGeometry(spec: spec, panelIndex: panelIndex, clockwiseQuarterTurns: orientation.clockwiseQuarterTurns,
                                   posture: posture, bezels: bezels)
    }

    public var layout: ViewerLayout {
        ViewerLayout(geometry: geometry, mode: scaleMode, windowWidth: windowWidth, windowHeight: windowHeight,
                     pixelDensity: pixelDensity, deviceScale: panel?.scale ?? hello?.scale ?? spec.panels[0].scale)
    }

    /// The shown picture's size in points (touch space as shown).
    public var shownPointSize: (width: Double, height: Double) {
        if let p = panel { return p.shownPointSize }
        if let h = hello { return (h.pointWidth, h.pointHeight) }
        let s = spec.panels[0].uprightPointSize
        return (Double(s.width), Double(s.height))
    }

    /// How far the front end turns the stream image clockwise to show it.
    public var imageRotation: Int { panel?.rotation ?? 0 }

    private func syncMapper() {
        let s = layout.screen, pts = shownPointSize
        mapper.viewWidth = s.width
        mapper.viewHeight = s.height
        mapper.pointWidth = pts.width
        mapper.pointHeight = pts.height
        mapper.panel = panel
    }

    // MARK: Input (window units)

    public var canTouch: Bool { hello?.touch ?? false }
    public var isWatch: Bool { spec.family == .watch }

    private func sendTouch(_ contacts: [TouchContact], label: String?) {
        guard !contacts.isEmpty else { return }
        let seq = client.sendInput(label: label) { .touch(sequence: $0, contacts: contacts) }
        probe(seq, label)
    }

    private func probe(_ seq: UInt32, _ label: String?) {
        guard seq != 0, let label else { return }
        pendingProbes.append((seq, viewerNanoseconds(), label))
    }

    // MARK: visionOS (SpatialInteraction; visionos.md "Ycode implementation")

    /// The server takes pose, selection and dial messages (its hello's `spatial`).
    public var isSpatial: Bool { hello?.spatial == true }

    private func syncSpatial() {
        let pts = shownPointSize
        spatial.width = pts.width
        spatial.height = pts.height
    }

    private func sendSelection(_ s: SpatialSelection, label: String?) {
        let seq = client.sendInput(label: label) { .selection(sequence: $0, selection: s) }
        probe(seq, label)
    }

    /// After a camera move: the pose, then the gaze again (it is in the stage frame).
    private func cameraMoved(_ pose: SpatialPose) {
        client.sendInput { .pose(sequence: $0, pose: pose) }
        if !spatial.isPinching { sendSelection(spatial.gazeSelection, label: nil) }
    }

    /// Alt + W A S D / arrows / E Q moves the camera, Alt + R resets it; true when used.
    public func spatialKey(usage: UInt16, down: Bool, alt: Bool) -> Bool {
        guard isSpatial, alt else { return false }
        guard down else { return usage == 0x15 || SpatialCameraKeys.direction(usage: usage) != nil }
        if usage == 0x15 {
            resetCamera()
            return true
        }
        guard let d = SpatialCameraKeys.direction(usage: usage) else { return false }
        cameraMoved(spatial.step(forward: d.forward, right: d.right, up: d.up))
        return true
    }

    /// Reset Camera: the default eye (§5.5.1).
    public func resetCamera() {
        guard isSpatial else { return }
        cameraMoved(spatial.resetCamera())
    }

    /// A mouse press: a frame button, or a touch on the screen; on a Vision
    /// Pro a pinch at the gaze (Alt: both hands; Ctrl: mouse-look).
    public func pointerDown(x: Double, y: Double, multiTouch: Bool, shift: Bool, control: Bool = false) {
        if isTakenOver { takeBack(); return }
        syncMapper()
        let l = layout
        if isSpatial, l.screen.contains(x, y) {
            syncSpatial()
            let p = mapper.devicePoint(l.screenPoint(x, y))
            if control {
                spatialLook = p
                return
            }
            sendSelection(spatial.press(x: p.x, y: p.y, twoHands: multiTouch), label: "pinch")
            return
        }
        if !l.screen.contains(x, y), let kind = l.button(atWindow: x, y) {
            let b = displayButton(for: kind)
            heldButton = b
            let seq = client.sendInput(label: b.name) { .button(sequence: $0, button: b, down: true) }
            probe(seq, b.name)
            return
        }
        guard l.screen.contains(x, y) else { return }
        sendTouch(mapper.down(l.screenPoint(x, y), multiTouch: multiTouch, shift: shift), label: "touch down")
    }

    public func pointerMoved(x: Double, y: Double, multiTouch: Bool, shift: Bool = false) {
        syncMapper()
        if isSpatial {
            syncSpatial()
            let d = mapper.devicePoint(layout.screenPoint(x, y))
            if let from = spatialLook {
                spatialLook = d
                cameraMoved(spatial.look(dx: d.x - from.x, dy: d.y - from.y))
            } else if spatial.isPinching {
                sendSelection(spatial.drag(x: d.x, y: d.y, depth: shift), label: nil)
            } else if layout.screen.contains(x, y) {
                sendSelection(spatial.hover(x: d.x, y: d.y), label: nil)
            }
            return
        }
        let p = layout.screenPoint(x, y)
        multiTouchHover = multiTouch ? p : nil
        if let c = mapper.drag(p) { sendTouch(c, label: nil) }
    }

    public func pointerUp(x: Double, y: Double) {
        if let b = heldButton {
            heldButton = nil
            client.sendInput { .button(sequence: $0, button: b, down: false) }
            return
        }
        if isSpatial {
            if spatialLook != nil { spatialLook = nil; return }
            if let s = spatial.release() { sendSelection(s, label: nil) }
            return
        }
        syncMapper()
        if let c = mapper.up(layout.screenPoint(x, y)) { sendTouch(c, label: nil) }
    }

    /// A wheel step at a window point; `dx`, `dy` in wheel units (lines),
    /// positive y away from the user. On a watch the crown turns instead.
    public func wheel(x: Double, y: Double, dx: Double, dy: Double, now: Double, alt: Bool = false) {
        if isSpatial {
            // Alt: the Digital Crown; else the camera left/right and up/down (0.04 m a line).
            if alt {
                let d = TouchMapper.crownDelta(scrollingDeltaY: dy, precise: false)
                if d != 0 { client.sendInput { .dial(sequence: $0, delta: d) } }
            } else if dx != 0 || dy != 0 {
                cameraMoved(spatial.step(forward: 0, right: -dx * 0.04 / SpatialInteraction.keyStep, up: dy * 0.04 / SpatialInteraction.keyStep))
            }
            return
        }
        if isWatch {
            let d = TouchMapper.crownDelta(scrollingDeltaY: dy, precise: false)
            if d != 0 { sendCommand(String(format: "crown %.3f", d)) { _ in } }
            return
        }
        syncMapper()
        let l = layout
        guard l.screen.contains(x, y) else { return }
        // Natural scrolling: the content follows the fingers (wheel away = content down).
        let steps = mapper.scroll(at: l.screenPoint(x, y), dx: -dx * 12, dy: dy * 12, now: now)
        for (i, c) in steps.enumerated() { sendTouch(c, label: i == 0 && c.first?.phase == .began ? "scroll" : nil) }
    }

    /// Ends a scroll after its idle time (call from the front end's loop).
    public func idle(now: Double) {
        if let c = mapper.endIdleScroll(now: now) { sendTouch(c, label: nil) }
    }

    /// The window lost focus: lift fingers and keys.
    public func cancelInput() {
        spatialLook = nil
        if isSpatial, let s = spatial.release() { sendSelection(s, label: nil) }
        if let c = mapper.cancel() { sendTouch(c, label: nil) }
        for u in pressedKeys { client.sendInput { .key(sequence: $0, down: false, usagePage: HIDKeys.keyboardPage, usage: u) } }
        pressedKeys.removeAll()
        multiTouchHover = nil
    }

    public func key(usage: UInt16, down: Bool) {
        if down {
            guard !pressedKeys.contains(usage) else { return }
            pressedKeys.insert(usage)
        } else {
            guard pressedKeys.remove(usage) != nil else { return }
        }
        let seq = client.sendInput(label: down ? "key" : nil) { .key(sequence: $0, down: down, usagePage: HIDKeys.keyboardPage, usage: usage) }
        if down { probe(seq, "key") }
    }

    /// Types US-layout text with key events.
    public func type(_ text: String) {
        for e in HIDKeys.events(typing: text) { key(usage: e.usage, down: e.down) }
    }

    /// A hardware button pressed and released (100 ms).
    public func press(_ b: DisplayButton) {
        // `action` is new (display-stream.md §5.3): only to a server that lists it.
        if b == .action, hello?.buttons.contains(b.name) != true { return }
        let seq = client.sendInput(label: b.name) { .button(sequence: $0, button: b, down: true) }
        probe(seq, b.name)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { [client] in
            client.sendInput { .button(sequence: $0, button: b, down: false) }
        }
    }

    /// The frame's buttons → the stream's, as the macOS viewer maps them
    /// (DeviceLiveSession; device-hub.md "Ycode implementation", watchos.md
    /// §5.2): side and top buttons are Sleep/Wake (`lock`), a phone's Action
    /// button the side usage; on a watch the crown is the crown press
    /// (`home`), the side button `side`, and an Ultra's Action button
    /// `action` only when the server lists it in its hello (`actionOnTheWire`;
    /// an older server takes `side`). The server turns them into usages with
    /// DeviceButtonTable.
    public static func displayButton(for kind: DeviceFrameGeometry.ButtonKind, watch: Bool = false,
                                     actionOnTheWire: Bool = false) -> DisplayButton {
        switch kind {
        case .side, .top: .lock
        case .sideButton: watch ? .side : .lock
        case .volumeUp: .volumeUp
        case .volumeDown: .volumeDown
        case .action: watch && actionOnTheWire ? .action : .side
        case .crown: .home
        }
    }

    /// This device's button for a frame button (above).
    public func displayButton(for kind: DeviceFrameGeometry.ButtonKind) -> DisplayButton {
        Self.displayButton(for: kind, watch: isWatch, actionOnTheWire: hello?.buttons.contains(DisplayButton.action.name) == true)
    }

    /// The control row's buttons (title, button): a watch's crown, side
    /// button, Action button (when the server lists it) and screen; else
    /// Home, Lock and, where the device has them, the volume buttons.
    public static func controlButtons(watch: Bool, volume: Bool, offered: [String]?) -> [(title: String, button: DisplayButton)] {
        if watch {
            var out: [(String, DisplayButton)] = [("Crown", .home), ("Side", .side)]
            if offered?.contains(DisplayButton.action.name) == true { out.append(("Action", .action)) }
            return out + [("Screen", .lock)]
        }
        return [("Home", .home), ("Lock", .lock)] + (volume ? [("Vol+", .volumeUp), ("Vol-", .volumeDown)] : [])
    }

    public var controlButtons: [(title: String, button: DisplayButton)] {
        Self.controlButtons(watch: isWatch, volume: spec.hasVolumeButtons, offered: hello?.buttons)
    }

    public var canRotate: Bool { hello?.rotation == true }

    public func rotate(left: Bool) {
        guard canRotate else { notice = ("This device does not rotate", Double(viewerNanoseconds()) / 1e9 + 3); return }
        client.send(.rotate(orientation: orientation.rotated(left: left).streamCode))
    }

    public func refreshDisplay() { client.send(.keyframeRequest) }

    public func sendCommand(_ text: String, reply: @escaping @Sendable (String) -> Void) {
        let token = client.token()
        lock.withLock { commandWaiters[token] = reply }
        if !client.send(.command(token: token, text: text)) {
            _ = lock.withLock { commandWaiters.removeValue(forKey: token) }
            reply("error: not connected")
        }
    }

    /// A full-resolution PNG from the server; `done` on the front end's thread (drain).
    public func requestScreenshot(_ done: @escaping @Sendable ([UInt8]) -> Void) {
        let token = client.token()
        screenshotWaiters[token] = done
        if !client.send(.screenshotRequest(token: token)) {
            screenshotWaiters.removeValue(forKey: token)
            done([])
        }
    }

    /// The image the viewer shows (the stream image, unturned) as a PNG.
    public func shownPNG() -> [UInt8]? {
        guard let c = client.currentCanvas else { return nil }
        return PNGWriter.encode(rgba: c.rgba(), width: c.width, height: c.height)
    }

    /// The touch indicator dots (window units).
    public var indicator: [ViewPoint] {
        syncMapper()
        let s = layout.screen
        return mapper.indicator(hover: multiTouchHover, multiTouch: multiTouchHover != nil).map { ViewPoint(x: $0.x + s.x, y: $0.y + s.y) }
    }

    // MARK: Text

    /// The status line: phase, frame rate, bandwidth, latency, round trip.
    public var statusText: String {
        var t = "\(phase) · \(framesPerSecond) fps · " + String(format: "%.0f KB/s", bandwidth / 1000)
        if let l = presentLatencies.last { t += String(format: " · input→shown %.0f ms", l.ms) }
        if let r = rttMilliseconds { t += String(format: " · rtt %.1f ms", r) }
        if let h = hello, !h.touch { t += " · input not delivered" }
        return t
    }

    public var problemText: String? {
        switch phase {
        case "connecting": phaseDetail == nil ? "Connecting display" : "Connecting display (\(phaseDetail!))"
        case "disconnected": "The device is not running or the connection dropped; reconnecting"
        case "booting": "Starting... \(uptimeMilliseconds / 1000) s"
        case "stopping": "The device is shutting down"
        case "live": hasImage ? nil : "Waiting for the first frame"
        case DisplayNotice.takenOverPhase: "Another viewer has this device (the headset, or a second window). Click to take it back."
        default: phase
        }
    }

    public var title: String {
        let name = spec.typeID == "unknown" ? hello?.deviceName ?? "Device" : spec.name
        return [name, hello?.osVersion].compactMap { $0 }.joined(separator: " - ")
    }
}
