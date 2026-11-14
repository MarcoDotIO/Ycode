// The Linux device window (display-stream.md §13; device-hub.md §4.4,
// §11.1, §11.2): an SDL 3 window with the device in Ycode's frame
// (DeviceFrameGeometry), the stream image in its screen, centred above the
// floating glass control capsules ([Home · Screenshot · Record] [Rotate │
// the Duo's poses], DeviceWindowChrome and DeviceControlsLayout, as the
// macOS canvas), a More Actions circle at the top right (Lock, the volume,
// the sound, the scale, bezels, the frame rate, Refresh Display), light and
// dark, tooltips, notices ("Screenshot Saved", "Starting..."), and an
// optional status line; mouse → touches, keys → HID usages, the frame's
// buttons clickable, the wheel a drag (a watch's crown). The renderer
// presents without vsync, as soon as a frame is decoded; only the rectangle
// the frame changed is uploaded to the texture. The frame's scaling filter
// and the presentation pacing are unchanged here.
//
// Shortcuts stay with the window while Ctrl is held: Ctrl+Shift+H Home,
// Ctrl+L Lock, Ctrl+Up/Down volume, Ctrl+Left/Right rotate, Ctrl+Shift+S
// screenshot, Ctrl+1/2/3 fit / point accurate / pixel accurate, Ctrl+B
// bezels, Ctrl+F the status line, Ctrl+R refresh, Ctrl+Q quit, Ctrl+M mute
// the sound, Ctrl+= / Ctrl+- the viewer's volume. Alt+drag is
// a pinch, Alt+Shift+drag a two-finger pan. Other keys go to the device
// (the Super key as the device's Command).

import Foundation
import YcodeDeviceModel
import YcodeDisplayStream
import YcodeRemoteViewer

public final class RemoteDeviceWindow: @unchecked Sendable {
    public let sdl: SDL
    public let session: RemoteDeviceSession
    public var showStatus = false { didSet { needsRedraw = true } }
    /// Light or dark (ViewerAppearance.resolve; ViewerMain sets it).
    public var appearance: ViewerAppearance = .light { didSet { needsRedraw = true } }
    var palette: ViewerPalette { .of(appearance) }
    /// The More Actions menu is open.
    public private(set) var menuOpen = false
    /// The control under the pointer (a DeviceCommand's name, or "more") and since when.
    private var hover: (key: String, since: Double)?
    private var tooltipShown = false
    /// Where screenshots go (Ctrl+Shift+S, the control row).
    public var captureDirectory: URL
    public var log: (String) -> Void = { print($0) }
    public var onClose: () -> Void = {}

    // MARK: The window's frame (DeviceWindowFrame): toolbar, canvas, inspector

    /// Draws the toolbar and the inspector (OpenViews, set by the viewer's
    /// main); nil: the bare canvas, as before (cross-platform-parity.md §13).
    public var chromeRenderer: ((DeviceChromeRequest, DeviceChromeRequest.Part) -> DeviceChromeImage?)? {
        didSet {
            // The window grows by the toolbar and the inspector around its canvas.
            if oldValue == nil, chromeRenderer != nil, window != nil {
                var w: Int32 = 0, h: Int32 = 0
                _ = sdl.GetWindowSize(window, &w, &h)
                let s = DeviceWindowFrame.windowSize(canvasWidth: Double(w), canvasHeight: Double(h), inspectorShown: inspectorShown)
                _ = sdl.SetWindowSize(window, Int32(s.width.rounded()), Int32(s.height.rounded()))
            }
            updateWindowMetrics()
        }
    }
    public var hasChrome: Bool { chromeRenderer != nil }
    /// The Settings inspector is shown (More Actions ▸ Show/Hide Inspector).
    public var inspectorShown = true { didSet { updateWindowMetrics() } }
    public private(set) var inspectorTab: DeviceWindowFrame.Item = .settingsTab
    /// Keys go to the device (the toolbar's Capture Keyboard).
    public private(set) var capturesKeyboard = true
    /// What the Settings tab shows.
    public var settingsContent = DeviceInspectorContent.standard(note: DeviceInspectorContent.notAvailableNote) { didSet { needsRedraw = true } }
    /// The frame in window units.
    public private(set) var frame = DeviceWindowFrame(width: 1, height: 1)
    /// Where canvas drawing goes in the window (the canvas's origin while it is drawn).
    private var origin = (x: 0.0, y: 0.0)
    private var chromeTextures: [Bool: (texture: UnsafeMutableRawPointer, request: DeviceChromeRequest, size: (Int, Int))] = [:]

    private var window: UnsafeMutableRawPointer!
    private var renderer: UnsafeMutableRawPointer!
    private var texture: UnsafeMutableRawPointer?
    private var textureSize = (0, 0)
    private var textureCanvas: ObjectIdentifier?
    private var textureFormat: UInt32 = 0
    private var textureScaleMode = SDLConst.scaleLinear
    private var running = true
    private var needsRedraw = true
    private var lastTick = viewerNanoseconds()
    private let wakeLock = NSLock()
    private var wakePending = false
    private var buttonDown = false
    private var lastMouse = (0.0, 0.0)
    private var pendingCaptures: [(String, @Sendable (Bool) -> Void)] = []
    /// The sequence of the last frame drawn (presented once).
    private var drawnSequence: UInt64 = 0
    public private(set) var rendererName = ""
    public private(set) var presentNanoseconds: UInt64 = 0
    public private(set) var uploads: (count: Int, ns: UInt64) = (0, 0)

    public init?(sdl: SDL, session: RemoteDeviceSession, captureDirectory: URL) {
        self.sdl = sdl
        self.session = session
        self.captureDirectory = captureDirectory
    }

    /// Creates the window; false (with a message) when SDL cannot.
    public func open(title: String = "Ycode Simulator", width: Int = 460, height: Int = 900) -> Bool {
        _ = sdl.SetHint("SDL_VIDEO_X11_NET_WM_BYPASS_COMPOSITOR", "0")
        guard sdl.Init(SDLConst.initVideo) else { log("ycode-sim-viewer: SDL_Init: \(sdl.error)"); return false }
        guard let w = sdl.CreateWindow(title, Int32(width), Int32(height), SDLConst.windowResizable | SDLConst.windowHighPixelDensity) else {
            log("ycode-sim-viewer: SDL_CreateWindow: \(sdl.error)"); return false
        }
        window = w
        let preferred = ProcessInfo.processInfo.environment["YCODE_SDL_RENDERER"]
        guard let r = preferred.flatMap({ sdl.CreateRenderer(w, $0) }) ?? sdl.CreateRenderer(w, nil) else {
            log("ycode-sim-viewer: SDL_CreateRenderer: \(sdl.error)"); return false
        }
        renderer = r
        rendererName = sdl.GetRendererName(r).map { String(cString: $0) } ?? "?"
        _ = sdl.SetRenderVSync(r, 0)
        _ = sdl.SetRenderDrawBlendMode(r, SDLConst.blendModeBlend)
        _ = sdl.StartTextInput(w)
        session.wake = { [weak self] in self?.wakeUp() }
        updateWindowMetrics()
        log("ycode-sim-viewer: SDL \(sdl.path), renderer \(rendererName)")
        return true
    }

    private func wakeUp() {
        let push = wakeLock.withLock { () -> Bool in defer { wakePending = true }; return !wakePending }
        guard push else { return }
        var e = SDLEvent()
        e.raw.withUnsafeMutableBytes { $0.storeBytes(of: SDLConst.user, toByteOffset: 0, as: UInt32.self) }
        e.raw.withUnsafeMutableBytes { _ = sdl.PushEvent($0.baseAddress!) }
    }

    /// The canvas in the window (the whole window without the chrome).
    var canvasRect: ViewerRect { hasChrome ? frame.canvas : ViewerRect(x: 0, y: 0, width: frame.width, height: frame.height) }

    /// The window size for a canvas of `size`.
    func windowSize(canvas size: (width: Double, height: Double)) -> (width: Double, height: Double) {
        hasChrome ? DeviceWindowFrame.windowSize(canvasWidth: size.width, canvasHeight: size.height, inspectorShown: inspectorShown) : size
    }

    private func updateWindowMetrics() {
        guard window != nil else { return }
        var w: Int32 = 0, h: Int32 = 0, pw: Int32 = 0, ph: Int32 = 0
        _ = sdl.GetWindowSize(window, &w, &h)
        _ = sdl.GetWindowSizeInPixels(window, &pw, &ph)
        frame = hasChrome ? DeviceWindowFrame(width: Double(w), height: Double(h), inspectorShown: inspectorShown)
            : DeviceWindowFrame(width: Double(w), height: Double(h), inspectorShown: false)
        let canvas = canvasRect
        session.hubFit = hasChrome
        session.windowWidth = canvas.width
        session.windowHeight = canvas.height
        session.pixelDensity = w > 0 ? Double(pw) / Double(w) : 1
        // Render in window units (SDL scales to pixels).
        _ = sdl.SetRenderScale(renderer, Float(session.pixelDensity), Float(session.pixelDensity))
        needsRedraw = true
    }

    /// Resizes the window to show the device at the current scale mode's size.
    public func fitWindowToDevice(scale: Double) {
        let s = windowSize(canvas: ViewerLayout.windowSize(geometry: session.geometry, scale: scale))
        _ = sdl.SetWindowSize(window, Int32(s.width.rounded()), Int32(s.height.rounded()))
        updateWindowMetrics()
    }

    /// Requests a PNG of the window's next drawing at `path`.
    public func captureWindow(to path: String, done: @escaping @Sendable (Bool) -> Void) {
        session.perform { [weak self] in
            self?.pendingCaptures.append((path, done))
            self?.needsRedraw = true
        }
    }

    public func stop() { session.perform { [weak self] in self?.running = false } }

    // MARK: The loop

    public func run() {
        var event = SDLEvent()
        var lastTitle = ""
        while running {
            let got = event.raw.withUnsafeMutableBytes { sdl.WaitEventTimeout($0.baseAddress!, 20) }
            if got {
                handle(event)
                while event.raw.withUnsafeMutableBytes({ sdl.PollEvent($0.baseAddress!) }) { handle(event) }
            }
            wakeLock.withLock { wakePending = false }
            if session.drain() { needsRedraw = true }
            let now = viewerNanoseconds()
            session.idle(now: Double(now) / 1e9)
            if now - lastTick >= 1_000_000_000 {
                lastTick = now
                session.tick(now: now)
                if showStatus || session.problemText != nil { needsRedraw = true }
            }
            if let h = hover, !tooltipShown, Double(now) / 1e9 - h.since >= DeviceWindowChrome.tooltipDelay {
                tooltipShown = true
                needsRedraw = true
            }
            if session.title != lastTitle {
                lastTitle = session.title
                _ = sdl.SetWindowTitle(window, lastTitle)
                needsRedraw = true
            }
            if needsRedraw { draw() }
        }
        session.cancelInput()
        if let texture { sdl.DestroyTexture(texture) }
        for (_, c) in chromeTextures { sdl.DestroyTexture(c.texture) }
        sdl.DestroyRenderer(renderer)
        sdl.DestroyWindow(window)
        sdl.QuitFn()
    }

    // MARK: Events

    private func handle(_ e: SDLEvent) {
        switch e.type {
        case SDLConst.quit, SDLConst.windowCloseRequested:
            running = false
            onClose()
        case SDLConst.windowResized, SDLConst.windowPixelSizeChanged, SDLConst.windowExposed:
            updateWindowMetrics()
        case SDLConst.windowFocusLost:
            session.cancelInput()
            buttonDown = false
        case SDLConst.mouseButtonDown where e.buttonIndex == 1:
            if frameClick(Double(e.buttonX), Double(e.buttonY)) { needsRedraw = true; return }
            let (x, y) = toCanvas(Double(e.buttonX), Double(e.buttonY))
            lastMouse = (x, y)
            if chromeClick(x, y, alt: sdl.GetModState() & SDLConst.kmodAlt != 0) { needsRedraw = true; return }
            buttonDown = true
            let mod = sdl.GetModState()
            session.pointerDown(x: x, y: y, multiTouch: mod & SDLConst.kmodAlt != 0, shift: mod & SDLConst.kmodShift != 0,
                                control: mod & SDLConst.kmodCtrl != 0)
            needsRedraw = true
        case SDLConst.mouseMotion:
            let (x, y) = toCanvas(Double(e.motionX), Double(e.motionY))
            lastMouse = (x, y)
            updateHover(x, y)
            let mod = sdl.GetModState()
            session.pointerMoved(x: x, y: y, multiTouch: mod & SDLConst.kmodAlt != 0, shift: mod & SDLConst.kmodShift != 0)
            needsRedraw = true
        case SDLConst.mouseButtonUp where e.buttonIndex == 1:
            buttonDown = false
            let (x, y) = toCanvas(Double(e.buttonX), Double(e.buttonY))
            session.pointerUp(x: x, y: y)
            needsRedraw = true
        case SDLConst.mouseWheel:
            let flip: Float = e.wheelFlipped ? -1 : 1
            let (wx, wy) = toCanvas(Double(e.wheelMouseX), Double(e.wheelMouseY))
            session.wheel(x: wx, y: wy, dx: Double(e.wheelX * flip), dy: Double(e.wheelY * flip),
                          now: Double(viewerNanoseconds()) / 1e9, alt: sdl.GetModState() & SDLConst.kmodAlt != 0)
        case SDLConst.windowMouseLeave:
            session.multiTouchHover = nil
            hover = nil
            tooltipShown = false
            needsRedraw = true
        case SDLConst.keyDown, SDLConst.keyUp:
            key(e)
        default:
            break
        }
    }

    private func key(_ e: SDLEvent) {
        let down = e.type == SDLConst.keyDown
        let mod = e.keyMod
        let sc = e.keyScancode
        if mod & SDLConst.kmodCtrl != 0 {
            if down, !e.keyRepeat { shortcut(sc, shift: mod & SDLConst.kmodShift != 0) }
            return
        }
        // Ctrl itself stays with the window; Capture Keyboard off: no keys
        // reach the device.
        if sc == 0xE0 || sc == 0xE4 || !capturesKeyboard { return }
        if e.keyRepeat { return }
        guard let u = HIDKeys.usage(sdlScancode: sc) else { return }
        // A Vision Pro: Alt + the camera keys move the camera (not sent to the device).
        if session.spatialKey(usage: u, down: down, alt: mod & SDLConst.kmodAlt != 0) { return }
        session.key(usage: u, down: down)
        if HIDKeys.isModifier(u) {
            session.pointerMoved(x: lastMouse.0, y: lastMouse.1, multiTouch: mod & SDLConst.kmodAlt != 0 || (u == 0xE2 || u == 0xE6) && down)
            needsRedraw = true
        }
    }

    private func shortcut(_ scancode: Int32, shift: Bool) {
        switch scancode {
        case 0x0B where shift: session.press(.home)                 // H
        case 0x0F: session.press(.lock)                             // L
        case 0x52: session.press(.volumeUp)                         // Up
        case 0x51: session.press(.volumeDown)                       // Down
        case 0x50: session.rotate(left: true)                       // Left
        case 0x4F: session.rotate(left: false)                      // Right
        case 0x16 where shift: screenshot()                         // S
        case 0x1E: setScale(.fit)                                   // 1
        case 0x1F: setScale(.point)                                 // 2
        case 0x20: setScale(.pixel)                                 // 3
        case 0x05: session.bezels.toggle(); needsRedraw = true      // B
        case 0x09: showStatus.toggle(); needsRedraw = true          // F
        case 0x15: session.refreshDisplay()                         // R
        case 0x14: running = false; onClose()                       // Q
        case 0x10: toggleMute()                                     // M
        case 0x2E: changeVolume(0.1)                                // =
        case 0x2D: changeVolume(-0.1)                               // -
        default: break
        }
    }

    /// The viewer's own mute and volume (the device's volume buttons act on the guest).
    public func toggleMute() {
        guard let a = session.audio else { return }
        a.muted.toggle()
        log("audio: \(a.muted ? "muted" : "unmuted")")
        needsRedraw = true
    }

    public func changeVolume(_ d: Float) {
        guard let a = session.audio else { return }
        a.volume = max(0, min(1, a.volume + d))
        log("audio: volume \(Int(a.volume * 100)) %")
        needsRedraw = true
    }

    public func setScale(_ m: ViewerScaleMode) {
        session.scaleMode = m
        session.scaleChosen = true
        if m != .fit {
            let scale = ViewerLayout(geometry: session.geometry, mode: m, windowWidth: 1, windowHeight: 1, pixelDensity: session.pixelDensity,
                                     deviceScale: session.panel?.scale ?? session.hello?.scale ?? 3).scale
            fitWindowToDevice(scale: scale)
        }
        needsRedraw = true
    }

    /// Saves the server's full-resolution PNG (the shown image when none).
    public func screenshot() {
        let dir = captureDirectory
        let name = DeviceCaptureFileName.screenshot(device: session.title)
        session.requestScreenshot { [weak self] png in
            guard let self else { return }
            let bytes = png.isEmpty ? (self.session.shownPNG() ?? []) : png
            let url = dir.appendingPathComponent(name)
            if !bytes.isEmpty, (try? Data(bytes).write(to: url)) != nil {
                self.log("screenshot: \(url.path)")
                self.session.showNotice("Screenshot Saved to \(dir.lastPathComponent)")
            } else {
                self.log("screenshot failed")
                self.session.showNotice("Screenshot Failed", seconds: 3)
            }
            self.needsRedraw = true
        }
    }

    // MARK: Chrome (the capsules, More Actions, tooltips)

    var menuItems: [ViewerMenuItem] {
        session.moreItems(muted: session.audio?.muted, statusLine: showStatus, inspector: hasChrome ? inspectorShown : nil)
    }

    /// The menu's anchor in canvas units: the toolbar's More Actions.
    var menuAnchor: ViewerRect? {
        guard hasChrome, let m = frame.rect(of: .more) else { return nil }
        let c = canvasRect
        return ViewerRect(x: m.x - c.x, y: m.y - c.y, width: m.width, height: m.height)
    }

    /// A window point in canvas units.
    func toCanvas(_ x: Double, _ y: Double) -> (Double, Double) {
        let c = canvasRect
        return (x - c.x, y - c.y)
    }

    /// A click on the toolbar or the inspector (window units); true: taken.
    private func frameClick(_ x: Double, _ y: Double) -> Bool {
        guard hasChrome else { return false }
        if menuOpen, frame.item(at: x, y) != .more {
            // The menu reaches over the toolbar: let the canvas handler close it.
            return false
        }
        if frame.toolbar.contains(x, y) {
            if let item = frame.item(at: x, y) { toolbar(item) }
            return true
        }
        return frame.inspector?.contains(x, y) == true
    }

    /// A toolbar item's action.
    public func toolbar(_ item: DeviceWindowFrame.Item) {
        switch item {
        case .captureKeyboard:
            capturesKeyboard.toggle()
            if !capturesKeyboard { session.cancelInput() }
        case .resizeMode: break
        case .zoomOut: setScale(session.scaleMode == .pixel ? .point : .fit)
        case .zoomFit: setScale(.fit)
        case .zoomActual: setScale(.point)
        case .zoomIn: setScale(session.scaleMode == .fit ? .point : .pixel)
        case .more: menuOpen.toggle(); hover = nil
        case .settingsTab, .reportsTab, .infoTab:
            // A tab shows the inspector when it is hidden, as on macOS.
            inspectorTab = item
            if !inspectorShown { inspectorShown = true }
        }
        needsRedraw = true
    }

    /// What the inspector shows for its tab (Ycode's choice for Reports
    /// and Info: the device's facts, or that there are no reports).
    var inspectorContent: DeviceInspectorContent {
        switch inspectorTab {
        case .infoTab:
            let h = session.hello
            let rows: [DeviceInspectorContent.Row] = [
                .init(symbol: "iphone", label: "Name", control: .popUp(session.title), enabled: true),
                .init(symbol: "cpu", label: "Model", control: .popUp(h?.model ?? session.spec.name), enabled: true),
                .init(symbol: "gearshape", label: "OS", control: .popUp(h == nil ? "—" : session.osTitle), enabled: true),
            ]
            return DeviceInspectorContent(cards: [rows], note: nil)
        case .reportsTab: return DeviceInspectorContent(cards: [], note: "No Reports")
        default: return settingsContent
        }
    }

    /// The toolbar's title and subtitle: the device and its OS.
    /// (an iPad's OS is "iPadOS 27.2", §15.5).
    var subtitle: String { session.osTitle }

    /// A click on the chrome; true: it was the chrome's (not the device's).
    private func chromeClick(_ x: Double, _ y: Double, alt: Bool) -> Bool {
        let more = DeviceWindowChrome.moreButton(windowWidth: session.windowWidth)
        if menuOpen {
            let items = menuItems
            if let i = DeviceWindowChrome.menuItem(at: x, y, items: items, windowWidth: session.windowWidth, anchor: menuAnchor) { run(items[i]) }
            menuOpen = false
            return true
        }
        if !hasChrome, more.contains(x, y) { menuOpen = true; hover = nil; return true }
        if let c = session.control(at: x, y) {
            if c.enabled { perform(c.command, alt: alt) }
            return true
        }
        return session.controlCapsules.contains { $0.contains(x, y) }
    }

    private func updateHover(_ x: Double, _ y: Double) {
        let key: String? = !hasChrome && DeviceWindowChrome.moreButton(windowWidth: session.windowWidth).contains(x, y) ? "more"
            : session.control(at: x, y)?.command.rawValue
        guard key != hover?.key else { return }
        hover = key.map { ($0, Double(viewerNanoseconds()) / 1e9) }
        if tooltipShown { needsRedraw = true }
        tooltipShown = false
    }

    /// Carries out a capsule control (Alt-click on Rotate: right, as Option-click on macOS).
    public func perform(_ c: DeviceCommand, alt: Bool = false) {
        // A capsule control while the device is not live says why (row 175:
        // its glyph stays at full contrast).
        if let reason = session.controlsUnavailableReason, session.controlGroups.joined().contains(c), c != .recordScreen {
            session.showNotice(reason, seconds: 3)
            needsRedraw = true
            return
        }
        switch c {
        case .home: session.press(.home)
        case .lock: session.press(.lock)
        case .volumeUp: session.press(.volumeUp)
        case .volumeDown: session.press(.volumeDown)
        case .screenshot: screenshot()
        case .recordScreen: session.showNotice("Record Screen is not in this beta", seconds: 3)
        case .rotateLeft: session.rotate(left: !alt)
        case .rotateRight: session.rotate(left: false)
        case .resetCamera: session.resetCamera()
        // A watch's capsule (row 234): the frame's buttons, pressed.
        case .sideButton: session.press(session.displayButton(for: .sideButton))
        case .digitalCrown: session.press(session.displayButton(for: .crown))
        case .poseClosed: session.fold(to: DevicePosture.closed.angle)
        case .posePartiallyOpen: session.fold(to: DevicePosture.halfOpen.angle)
        case .poseOpen: session.fold(to: DevicePosture.openFlat.angle)
        case .toggleBezels: session.bezels.toggle()
        default: break
        }
        needsRedraw = true
    }

    private func run(_ item: ViewerMenuItem) {
        switch item.action {
        case .command(let c)?: perform(c)
        case .mute?: toggleMute()
        case .scale(let m)?: setScale(m)
        case .statusLine?: showStatus.toggle()
        case .refresh?: session.refreshDisplay()
        case .inspector?: inspectorShown.toggle()
        case nil: break
        }
    }

    /// A script's `chrome` step (ViewerScript).
    public func chrome(_ words: [String]) -> Bool {
        defer { needsRedraw = true }
        switch (words.first, words.count > 1 ? words[1] : nil) {
        case ("more", _): menuOpen = true; return true
        case ("close", _): menuOpen = false; hover = nil; tooltipShown = false; return true
        case ("hover", let k?):
            guard k == "more" || session.controls.contains(where: { $0.command.rawValue == k }) else { return false }
            hover = (k, Double(viewerNanoseconds()) / 1e9)
            tooltipShown = false
            return true
        case ("click", let k?):
            guard let c = session.controls.first(where: { $0.command.rawValue == k }) else { return false }
            if c.enabled { perform(c.command) }
            return true
        case ("appearance", let a?):
            guard let v = ViewerAppearance(rawValue: a) else { return false }
            appearance = v
            return true
        case ("toolbar", let k?):
            guard hasChrome, let item = DeviceWindowFrame.Item(rawValue: k) else { return false }
            toolbar(item)
            return true
        case ("inspector", let k?):
            guard hasChrome, k == "show" || k == "hide" else { return false }
            inspectorShown = k == "show"
            return true
        case ("window", let k?):
            // `chrome window 1400x900`: the window's size (pictures at the council's sizes).
            let p = k.split(separator: "x").compactMap { Int32($0) }
            guard p.count == 2, p.allSatisfy({ $0 > 100 }) else { return false }
            _ = sdl.SetWindowSize(window, p[0], p[1])
            updateWindowMetrics()
            return true
        default: return false
        }
    }

    // MARK: Drawing

    private func color(_ r: UInt8, _ g: UInt8, _ b: UInt8, _ a: UInt8 = 255) { _ = sdl.SetRenderDrawColor(renderer, r, g, b, a) }

    private func fill(_ r: ViewerRect) {
        var f = SDLFRect(x: Float(r.x + origin.x), y: Float(r.y + origin.y), w: Float(r.width), h: Float(r.height))
        _ = sdl.RenderFillRect(renderer, &f)
    }

    /// A filled polygon (a fan around its first point; the shapes are convex).
    private func polygon(_ pts: [(Double, Double)], _ c: (Float, Float, Float, Float)) {
        guard pts.count >= 3 else { return }
        var verts = pts.map { SDLVertex(x: Float($0.0 + origin.x), y: Float($0.1 + origin.y), r: c.0, g: c.1, b: c.2, a: c.3, u: 0, v: 0) }
        var idx: [Int32] = []
        for i in 1..<(pts.count - 1) { idx += [0, Int32(i), Int32(i + 1)] }
        _ = verts.withUnsafeMutableBytes { v in idx.withUnsafeBufferPointer { sdl.RenderGeometry(renderer, nil, v.baseAddress!, Int32(pts.count), $0.baseAddress, Int32(idx.count)) } }
    }

    private func polygon(_ pts: [(Double, Double)], _ c: ViewerColor) { polygon(pts, (c.r, c.g, c.b, c.a)) }

    /// Triangles (three points each) in one colour.
    private func triangles(_ pts: [(Double, Double)], _ c: ViewerColor) {
        guard pts.count >= 3 else { return }
        var verts = pts.map { SDLVertex(x: Float($0.0 + origin.x), y: Float($0.1 + origin.y), r: c.r, g: c.g, b: c.b, a: c.a, u: 0, v: 0) }
        _ = verts.withUnsafeMutableBytes { sdl.RenderGeometry(renderer, nil, $0.baseAddress!, Int32(pts.count), nil, Int32(pts.count)) }
    }

    /// A convex polygon shaded from `top` (at its top) to `bottom`.
    private func gradientPolygon(_ pts: [(Double, Double)], top: ViewerColor, bottom: ViewerColor) {
        guard pts.count >= 3, let y0 = pts.map(\.1).min(), let y1 = pts.map(\.1).max() else { return }
        var verts = pts.map { p -> SDLVertex in
            let t = Float(y1 > y0 ? (p.1 - y0) / (y1 - y0) : 0)
            return SDLVertex(x: Float(p.0 + origin.x), y: Float(p.1 + origin.y), r: top.r + (bottom.r - top.r) * t, g: top.g + (bottom.g - top.g) * t,
                             b: top.b + (bottom.b - top.b) * t, a: top.a + (bottom.a - top.a) * t, u: 0, v: 0)
        }
        var idx: [Int32] = []
        for i in 1..<(pts.count - 1) { idx += [0, Int32(i), Int32(i + 1)] }
        _ = verts.withUnsafeMutableBytes { v in idx.withUnsafeBufferPointer { sdl.RenderGeometry(renderer, nil, v.baseAddress!, Int32(pts.count), $0.baseAddress, Int32(idx.count)) } }
    }

    private func circlePoints(_ cx: Double, _ cy: Double, _ r: Double, steps: Int = 24) -> [(Double, Double)] {
        (0..<steps).map { i in let a = Double(i) / Double(steps) * 2 * Double.pi; return (cx + cos(a) * r, cy + sin(a) * r) }
    }

    /// A disc with a soft edge (a faint ring half a unit outside).
    private func disc(_ cx: Double, _ cy: Double, _ r: Double, _ c: ViewerColor) {
        polygon(circlePoints(cx, cy, r + 0.5), c.with(alpha: c.a * 0.35))
        polygon(circlePoints(cx, cy, r), c)
    }

    /// A ring (centre radius `r`, `w` wide) from angle `a0` to `a1` (radians, clockwise from +x).
    private func arc(_ cx: Double, _ cy: Double, _ r: Double, _ w: Double, _ c: ViewerColor,
                     from a0: Double = 0, to a1: Double = 2 * Double.pi) {
        let steps = max(8, Int(abs(a1 - a0) / (2 * Double.pi) * 36))
        for (width, colour) in [(w + 0.8, c.with(alpha: c.a * 0.3)), (w, c)] {
            var tris: [(Double, Double)] = []
            for i in 0..<steps {
                let t0 = a0 + (a1 - a0) * Double(i) / Double(steps), t1 = a0 + (a1 - a0) * Double(i + 1) / Double(steps)
                let (ri, ro) = (r - width / 2, r + width / 2)
                let p0 = (cx + cos(t0) * ri, cy + sin(t0) * ri), p1 = (cx + cos(t0) * ro, cy + sin(t0) * ro)
                let p2 = (cx + cos(t1) * ri, cy + sin(t1) * ri), p3 = (cx + cos(t1) * ro, cy + sin(t1) * ro)
                tris += [p0, p1, p3, p0, p3, p2]
            }
            triangles(tris, colour)
        }
    }

    /// A polyline `w` wide (round joins), with a soft edge.
    private func stroke(_ pts: [(Double, Double)], _ w: Double, _ c: ViewerColor, closed: Bool = false) {
        let all = closed ? pts + [pts[0]] : pts
        for (width, colour) in [(w + 0.8, c.with(alpha: c.a * 0.3)), (w, c)] {
            var tris: [(Double, Double)] = []
            for (a, b) in zip(all, all.dropFirst()) {
                let dx = b.0 - a.0, dy = b.1 - a.1, len = max(0.0001, (dx * dx + dy * dy).squareRoot())
                let nx = -dy / len * width / 2, ny = dx / len * width / 2
                let q = [(a.0 + nx, a.1 + ny), (b.0 + nx, b.1 + ny), (b.0 - nx, b.1 - ny), (a.0 - nx, a.1 - ny)]
                tris += [q[0], q[1], q[2], q[0], q[2], q[3]]
            }
            triangles(tris, colour)
        }
        let joints = closed ? pts : Array(pts.dropFirst().dropLast())
        for p in joints { polygon(circlePoints(p.0, p.1, w / 2, steps: 10), c) }
    }

    /// A rounded rectangle's outline as points.
    private func roundedRect(_ r: ViewerRect, radius: Double) -> [(Double, Double)] {
        ViewerLayout.roundedPolygon(r, radii: CornerRadii(all: radius), scale: 1, steps: 6)
    }

    /// The glass capsule (§11.1): a soft shadow, the rim, the fill shaded top to bottom.
    private func glass(_ r: ViewerRect) {
        let p = palette
        let radius = r.height / 2
        for (grow, dy, alpha) in [(3.0, 2.0, 0.35), (1.5, 1.0, 0.6)] as [(Double, Double, Float)] {
            let s = ViewerRect(x: r.x - grow, y: r.y - grow + dy, width: r.width + 2 * grow, height: r.height + 2 * grow)
            polygon(roundedRect(s, radius: s.height / 2), p.shadow.with(alpha: p.shadow.a * alpha))
        }
        gradientPolygon(roundedRect(r, radius: radius), top: p.rimTop, bottom: p.rimBottom)
        // A 0.5-point rim (§12.1).
        let inner = ViewerRect(x: r.x + 0.5, y: r.y + 0.5, width: r.width - 1, height: r.height - 1)
        gradientPolygon(roundedRect(inner, radius: inner.height / 2), top: p.glassTop, bottom: p.glassBottom)
    }

    /// Ycode's own glyph of a control, centred at (cx, cy) (§11.1's
    /// descriptions; no Apple artwork).
    private func glyph(_ c0: DeviceCommand, _ cx: Double, _ cy: Double, colour g: ViewerColor, highlighted: Bool) {
        switch c0 {
        case .home:
            // A 3 × 3 grid of rounded squares (§15.6), the macOS drawing.
            shared(DeviceControlGlyphs.home, cx, cy, line: g, fill: nil)
        case .screenshot:
            // A camera inside a viewfinder frame.
            let h = 7.5, arm = 3.2
            for (sx, sy) in [(-1.0, -1.0), (1.0, -1.0), (1.0, 1.0), (-1.0, 1.0)] {
                stroke([(cx + sx * h, cy + sy * (h - arm)), (cx + sx * h, cy + sy * h), (cx + sx * (h - arm), cy + sy * h)], 1.3, g)
            }
            stroke(roundedRect(ViewerRect(x: cx - 4.2, y: cy - 2.4, width: 8.4, height: 5.6), radius: 1.2), 1.1, g, closed: true)
            stroke([(cx - 1.5, cy - 2.4), (cx - 0.9, cy - 3.6), (cx + 0.9, cy - 3.6), (cx + 1.5, cy - 2.4)], 1.0, g)
            arc(cx, cy + 0.4, 1.3, 1.0, g)
        case .recordScreen:
            // A dot in a ring.
            arc(cx, cy, 7, 1.4, g)
            disc(cx, cy, 3.9, g)
        case .rotateLeft:
            // Ycode's Rotate (§13.1): a square with curved arrows at two
            // opposite corners, the shapes the macOS window draws too.
            shared(DeviceControlGlyphs.rotate, cx, cy, line: g, fill: nil)
        case .sideButton:
            // A watch's side button and Digital Crown (row 234), the macOS drawings.
            shared(DeviceControlGlyphs.sideButton, cx, cy, line: g, fill: nil)
        case .digitalCrown:
            shared(DeviceControlGlyphs.digitalCrown, cx, cy, line: g, fill: nil)
        case .resetCamera:
            // A circular arrow.
            arc(cx, cy, 6.5, 1.4, g, from: -0.35 * Double.pi, to: 1.35 * Double.pi)
            let a = -0.35 * Double.pi
            let tip = (cx + cos(a) * 6.5, cy + sin(a) * 6.5)
            polygon([(tip.0 - 3.2, tip.1 - 1.5), (tip.0 + 1.5, tip.1 - 3), (tip.0 + 0.5, tip.1 + 2)], g)
        case .poseClosed, .posePartiallyOpen, .poseOpen:
            // The current posture in the accent colour over its fill, the
            // others in the glyph colour over grey (§13.1), dimmed with the
            // glyph when disabled.
            let c = DeviceControlGlyphs.postureColours(current: highlighted, dark: appearance == .dark)
            let posture: DeviceControlGlyphs.Posture = c0 == .poseClosed ? .closed : c0 == .posePartiallyOpen ? .halfOpen : .flat
            shared(DeviceControlGlyphs.posture(posture), cx, cy, line: ViewerColor(c.line, alpha: g.a), fill: ViewerColor(c.fill, alpha: g.a))
        default:
            disc(cx, cy, 2, g)
        }
    }

    /// A shared glyph (`DeviceControlGlyphs`) centred at (cx, cy): its fills
    /// in `fill`, its lines and solids in `line`.
    private func shared(_ g: DeviceControlGlyphs.Glyph, _ cx: Double, _ cy: Double, line: ViewerColor, fill: ViewerColor?) {
        func points(_ s: DeviceControlGlyphs.Shape) -> (pts: [(Double, Double)], closed: Bool) {
            switch s {
            case .roundedRect(let x, let y, let w, let h, let r):
                return (DeviceControlGlyphs.outline(x: x, y: y, width: w, height: h, radius: r).map { (cx + $0.x, cy + $0.y) }, true)
            case .arc(let c, let r, let f, let t):
                return (DeviceControlGlyphs.arcPoints(centre: c, radius: r, from: f, to: t).map { (cx + $0.x, cy + $0.y) }, false)
            case .polygon(let p): return (p.map { (cx + $0.x, cy + $0.y) }, true)
            case .polyline(let p): return (p.map { (cx + $0.x, cy + $0.y) }, false)
            case .disc(let c, let r): return (circlePoints(cx + c.x, cy + c.y, r, steps: 12), true)
            }
        }
        if let fill { for s in g.fills { polygon(points(s).pts, fill) } }
        for s in g.strokes {
            let q = points(s)
            stroke(q.pts, g.lineWidth, line, closed: q.closed)
        }
        for s in g.solids { polygon(points(s).pts, line) }
    }

    /// A text box with the debug font: the tooltip, the notice, menu rows.
    private func label(_ s: String, x: Double, y: Double, _ c: ViewerColor) {
        let b = c.bytes
        color(b.0, b.1, b.2, b.3)
        text(s, x: x, y: y)
    }

    private func drawChrome() {
        let p = palette
        // The capsules (§11.1).
        for r in session.controlCapsules { glass(r) }
        for x in session.controlDividers {
            let caps = session.controlCapsules
            let y = (caps.first?.y ?? 0) + (DeviceControlsLayout.height - DeviceControlsLayout.dividerHeight) / 2
            let d = p.divider.bytes
            color(d.0, d.1, d.2, d.3)
            fill(ViewerRect(x: x - 0.5, y: y, width: 1, height: DeviceControlsLayout.dividerHeight))
        }
        for c in session.controls {
            let g = c.enabled ? p.glyph : p.glyph.with(alpha: p.disabledAlpha)
            glyph(c.command, c.rect.x + c.rect.width / 2, c.rect.y + c.rect.height / 2, colour: g, highlighted: c.highlighted)
        }
        // More Actions (in the toolbar when the window has one).
        let more = DeviceWindowChrome.moreButton(windowWidth: session.windowWidth)
        if !hasChrome {
            glass(more)
            for i in -1...1 { disc(more.x + more.width / 2 + Double(i) * 5, more.y + more.height / 2, 1.5, p.glyph) }
        }
        drawFrameChrome()
        // The notice ("Screenshot Saved", …) in a glass capsule at the top.
        if let n = session.notice {
            let w = Double(n.text.count) * 8 + 28
            let r = ViewerRect(x: (session.windowWidth - w) / 2, y: 12, width: w, height: 30)
            glass(r)
            label(n.text, x: r.x + 14, y: r.y + 11, p.text)
        }
        if menuOpen { drawMenu() }
        // The tooltip.
        if tooltipShown, let h = hover {
            let target: (ViewerRect, String)? = h.key == "more" ? (more, "More Actions")
                : session.controls.first { $0.command.rawValue == h.key }.map { ($0.rect, $0.help) }
            if let (rect, help) = target, !menuOpen {
                var r = DeviceWindowChrome.tooltipRect(for: rect, text: help, windowWidth: session.windowWidth)
                if h.key == "more" { r.y = more.y + more.height + 6 }
                polygon(roundedRect(r, radius: 5), p.menuRim)
                polygon(roundedRect(ViewerRect(x: r.x + 1, y: r.y + 1, width: r.width - 2, height: r.height - 2), radius: 4), p.menuFill.with(alpha: 1))
                label(help, x: r.x + 8, y: r.y + 7, p.text)
            }
        }
    }

    /// The toolbar and the inspector (window units), from the renderer's
    /// pictures, drawn over the canvas (a device larger than the canvas
    /// goes under them).
    private func drawFrameChrome() {
        guard let render = chromeRenderer else { return }
        let saved = origin
        origin = (0, 0)
        defer { origin = saved }
        let request = DeviceChromeRequest(frame: frame, title: session.title, subtitle: subtitle, dark: appearance == .dark,
                                          scaleMode: session.scaleMode, capturesKeyboard: capturesKeyboard, inspectorTab: inspectorTab,
                                          inspector: inspectorContent, pixelDensity: session.pixelDensity)
        let parts: [(DeviceChromeRequest.Part, ViewerRect?)] = [(.toolbar, frame.toolbar), (.inspector, frame.inspector)]
        for (part, rect) in parts {
            guard let rect else { continue }
            let key = part == .toolbar
            if chromeTextures[key]?.request != request, let img = render(request, part), img.width > 0, img.height > 0 {
                if let old = chromeTextures[key], old.size != (img.width, img.height) {
                    sdl.DestroyTexture(old.texture)
                    chromeTextures[key] = nil
                }
                let tex = chromeTextures[key]?.texture
                    ?? sdl.CreateTexture(renderer, SDLConst.pixelFormatABGR8888, SDLConst.textureStreaming, Int32(img.width), Int32(img.height))
                if let tex {
                    _ = img.rgba.withUnsafeBytes { sdl.UpdateTexture(tex, nil, $0.baseAddress!, Int32(img.width * 4)) }
                    chromeTextures[key] = (tex, request, (img.width, img.height))
                }
            }
            guard let tex = chromeTextures[key]?.texture else { continue }
            var dst = SDLFRect(x: Float(rect.x), y: Float(rect.y), w: Float(rect.width), h: Float(rect.height))
            _ = sdl.RenderTexture(renderer, tex, nil, &dst)
        }
    }

    private func drawMenu() {
        let p = palette
        let items = menuItems
        let r = DeviceWindowChrome.menuRect(items: items, windowWidth: session.windowWidth, anchor: menuAnchor)
        polygon(roundedRect(ViewerRect(x: r.x - 1, y: r.y + 1, width: r.width + 2, height: r.height + 2), radius: 9), p.shadow.with(alpha: p.shadow.a * 2))
        polygon(roundedRect(r, radius: 8), p.menuRim)
        polygon(roundedRect(ViewerRect(x: r.x + 1, y: r.y + 1, width: r.width - 2, height: r.height - 2), radius: 7), p.menuFill)
        let hovered = DeviceWindowChrome.menuItem(at: lastMouse.0, lastMouse.1, items: items, windowWidth: session.windowWidth, anchor: menuAnchor)
        var y = r.y + 4
        for (i, item) in items.enumerated() {
            if item.isSeparator {
                let d = p.divider.bytes
                color(d.0, d.1, d.2, d.3)
                fill(ViewerRect(x: r.x + 10, y: y + 4, width: r.width - 20, height: 1))
                y += DeviceWindowChrome.separatorHeight
                continue
            }
            let row = ViewerRect(x: r.x + 5, y: y, width: r.width - 10, height: DeviceWindowChrome.menuRowHeight)
            let on = hovered == i
            if on { polygon(roundedRect(row, radius: 5), p.menuHighlight) }
            let tc = on ? p.menuHighlightText : item.enabled ? p.text : p.secondaryText
            if item.checked { stroke([(row.x + 5, y + 11), (row.x + 8, y + 14.5), (row.x + 13.5, y + 7)], 1.5, tc) }
            label(item.title, x: row.x + 18, y: y + 7, tc)
            label(item.shortcut, x: row.x + row.width - 8 - Double(item.shortcut.count) * 8, y: y + 7, on ? tc : p.secondaryText)
            y += DeviceWindowChrome.menuRowHeight
        }
    }

    /// A convex polygon filled with the texture: each vertex's texture
    /// coordinate is its place in `rect`, turned back by `rotation` (the
    /// image is shown turned clockwise by it).
    private func texturedPolygon(_ pts: [(Double, Double)], in rect: ViewerRect, rotation: Int, texture: UnsafeMutableRawPointer) {
        guard pts.count >= 3 else { return }
        let turns = (((rotation % 360) + 360) % 360) / 90
        var verts = pts.map { p -> SDLVertex in
            let u = (p.0 - rect.x) / rect.width, v = (p.1 - rect.y) / rect.height
            let (tu, tv): (Double, Double)
            switch turns {
            case 1: (tu, tv) = (v, 1 - u)
            case 2: (tu, tv) = (1 - u, 1 - v)
            case 3: (tu, tv) = (1 - v, u)
            default: (tu, tv) = (u, v)
            }
            return SDLVertex(x: Float(p.0 + origin.x), y: Float(p.1 + origin.y), r: 1, g: 1, b: 1, a: 1, u: Float(tu), v: Float(tv))
        }
        var idx: [Int32] = []
        for i in 1..<(pts.count - 1) { idx += [0, Int32(i), Int32(i + 1)] }
        _ = verts.withUnsafeMutableBytes { v in idx.withUnsafeBufferPointer { sdl.RenderGeometry(renderer, texture, v.baseAddress!, Int32(pts.count), $0.baseAddress, Int32(idx.count)) } }
    }

    private func text(_ s: String, x: Double, y: Double, scale: Float = 1) {
        if scale != 1 { _ = sdl.SetRenderScale(renderer, scale * Float(session.pixelDensity), scale * Float(session.pixelDensity)) }
        _ = sdl.RenderDebugText(renderer, Float(x + origin.x) / scale, Float(y + origin.y) / scale, s)
        if scale != 1 { _ = sdl.SetRenderScale(renderer, Float(session.pixelDensity), Float(session.pixelDensity)) }
    }

    private func uploadFrame() -> UInt64? {
        guard let canvas = session.client.currentCanvas else { return nil }
        let id = ObjectIdentifier(canvas)
        // Video pictures stay NV12: the renderer converts them (on the GPU where it has one).
        let format = canvas.format == .nv12 ? SDLConst.pixelFormatNV12 : SDLConst.pixelFormatXRGB8888
        if texture == nil || textureSize != (canvas.width, canvas.height) || textureCanvas != id || textureFormat != format {
            if let texture { sdl.DestroyTexture(texture) }
            texture = sdl.CreateTexture(renderer, format, SDLConst.textureStreaming, Int32(canvas.width), Int32(canvas.height))
            if let texture { _ = sdl.SetTextureScaleMode(texture, SDLConst.scaleLinear) }
            textureScaleMode = SDLConst.scaleLinear
            textureSize = (canvas.width, canvas.height)
            textureCanvas = id
            textureFormat = format
            canvas.invalidate()
        }
        guard let texture else { return nil }
        let t0 = viewerNanoseconds()
        if format == SDLConst.pixelFormatNV12 {
            _ = canvas.withNV12 { y, uv, pitch, changed in
                if changed { _ = sdl.UpdateNVTexture(texture, nil, y, Int32(pitch), uv, Int32(pitch)) }
            }
            uploads.count += 1
            uploads.ns += viewerNanoseconds() - t0
            return session.lastFrame?.frame.sequence
        }
        canvas.withPixels { p, row, d in
            guard !d.isEmpty else { return }
            var r = SDLRect(x: Int32(d.x), y: Int32(d.y), w: Int32(d.width), h: Int32(d.height))
            _ = sdl.UpdateTexture(texture, &r, p + d.y * row + d.x * 4, Int32(row))
        }
        uploads.count += 1
        uploads.ns += viewerNanoseconds() - t0
        return session.lastFrame?.frame.sequence
    }

    private func draw() {
        needsRedraw = false
        // The window takes the device's shape when it connects (and when a
        // foldable shows another panel or turns).
        if let canvasSize = session.windowFitIfNeeded() {
            let size = windowSize(canvas: canvasSize)
            _ = sdl.SetWindowSize(window, Int32(size.width.rounded()), Int32(size.height.rounded()))
            updateWindowMetrics()
        }
        let l = session.layout
        let g = l.geometry
        let bg = palette.canvas.bytes
        color(bg.0, bg.1, bg.2)
        _ = sdl.RenderClear(renderer)
        // The canvas's drawing in canvas units, placed below the toolbar.
        origin = (canvasRect.x, canvasRect.y)
        defer { origin = (0, 0) }
        let body = l.window(g.body), screen = l.screen
        let framed = session.bezels && session.spec.hasFrame
        if framed, !g.bandRings.isEmpty {
            // The macOS frame's drawing (DeviceFrameView, device-hub.md
            // §14.2, §15.3–§15.4): a foldable cover's hinge step under
            // everything, the buttons, the band's tones outside in (a classic
            // iPhone's and an iPad's light line, grey band and black; a
            // foldable's mid grey and black), then flush buttons over the band.
            typealias P = DeviceFrameGeometry.Palette
            if let step = g.hingeStep {
                polygon(ViewerLayout.roundedPolygon(l.window(step), radii: g.hingeStepRadii, scale: l.scale), ViewerColor(P.step))
            }
            for b in g.buttons where !b.flush {
                polygon(ViewerLayout.roundedPolygon(l.window(b.rect), radii: CornerRadii(all: 1.5), scale: l.scale, steps: 3), ViewerColor(P.button))
            }
            for ring in g.bandRingRects {
                polygon(ViewerLayout.roundedPolygon(l.window(ring.rect), radii: ring.radii, scale: l.scale), ViewerColor(ring.color))
            }
            for b in g.buttons where b.flush {
                let c = ViewerColor(P.flushButton).bytes
                color(c.0, c.1, c.2, c.3)
                fill(l.window(b.rect))
            }
        } else if framed, g.drawsWatchCase {
            // A watch's case (council round 10 rows 250–251), the macOS
            // frame's profile (`WatchCaseDrawing`, `WatchCaseView`).
            drawWatchCase(l)
        } else if framed {
            for b in g.buttons {
                color(0x45, 0x46, 0x4B)
                fill(l.window(b.rect))
            }
            polygon(ViewerLayout.roundedPolygon(body, radii: g.bodyRadii, scale: l.scale), (0.30, 0.30, 0.33, 1))
            let inner = ViewerRect(x: body.x + 1.5, y: body.y + 1.5, width: body.width - 3, height: body.height - 3)
            polygon(ViewerLayout.roundedPolygon(inner, radii: g.bodyRadii.grown(by: -1.5 / max(l.scale, 0.01)), scale: l.scale), (0.06, 0.06, 0.07, 1))
        }
        // The screen: a rounded polygon, textured with the stream image
        // (turned for a turned panel); black until the first frame.
        let outline = ViewerLayout.roundedPolygon(screen, radii: g.screenRadii, scale: l.scale, steps: 12)
        var sequence: UInt64?
        if session.hasImage { sequence = uploadFrame() }
        if session.hasImage, let texture {
            // One stream pixel per output pixel (Pixel Accurate): unfiltered,
            // exact; any other size is filtered (uikit-feel-ycode.md §8.4).
            let turned = (((session.imageRotation % 360) + 360) % 360) / 90 % 2 == 1
            let (iw, ih) = turned ? (textureSize.1, textureSize.0) : (textureSize.0, textureSize.1)
            let mode = l.showsPixelsOneToOne(imageWidth: iw, imageHeight: ih) ? SDLConst.scaleNearest : SDLConst.scaleLinear
            if mode != textureScaleMode {
                _ = sdl.SetTextureScaleMode(texture, mode)
                textureScaleMode = mode
            }
            texturedPolygon(outline, in: screen, rotation: session.imageRotation, texture: texture)
        } else {
            polygon(outline, (0, 0, 0, 1))
        }
        if let problem = session.problemText {
            color(0xC8, 0xC8, 0xCC)
            let w = Double(problem.count) * 8
            text(problem, x: screen.x + max(4, (screen.width - w) / 2), y: screen.y + screen.height / 2 - 4)
        }
        if let s = g.shadedArea {
            color(0, 0, 0, 90)
            fill(l.window(s))
        }
        for p in session.indicator {
            var pts: [(Double, Double)] = []
            for i in 0..<20 { let a = Double(i) / 20 * 2 * Double.pi; pts.append((p.x + cos(a) * 12, p.y + sin(a) * 12)) }
            polygon(pts, (1, 1, 1, 0.35))
        }
        if showStatus {
            color(0, 0, 0, 160)
            fill(ViewerRect(x: 0, y: 0, width: session.windowWidth, height: 14))
            color(0x9F, 0xE8, 0x9F)
            text(session.statusText, x: 4, y: 3)
        }
        drawChrome()
        if !pendingCaptures.isEmpty { captureNow() }
        let t0 = viewerNanoseconds()
        _ = sdl.RenderPresent(renderer)
        let t1 = viewerNanoseconds()
        presentNanoseconds += t1 - t0
        if let sequence, sequence != drawnSequence {
            drawnSequence = sequence
            session.presented(sequence: sequence, at: t1)
        }
    }

    /// A watch's crown, side button and Action button, each rim-outlined and
    /// dark inside (the crown's ridges on its outer third), under the body's
    /// rim, band and fade to black (`WatchCaseDrawing`).
    private func drawWatchCase(_ l: ViewerLayout) {
        let g = l.geometry
        for b in g.buttons {
            shadeProfile(b.rect, radii: b.radii ?? CornerRadii(all: 1.5), stops: WatchCaseDrawing.buttonStops, l)
            if b.kind == .crown {
                for seg in WatchCaseDrawing.ridges(crown: b.rect) {
                    stroke([windowPoint(seg.from, l), windowPoint(seg.to, l)], max(0.5, WatchCaseDrawing.ridgeWidth * l.scale),
                           ViewerColor(WatchCaseDrawing.ridge))
                }
            }
        }
        shadeProfile(g.body, radii: g.bodyRadii, stops: WatchCaseDrawing.caseStops, l)
    }

    private func windowPoint(_ p: CGPoint, _ l: ViewerLayout) -> (Double, Double) {
        let w = l.window(CGRect(x: p.x, y: p.y, width: 0, height: 0))
        return (w.x, w.y)
    }

    /// A profile (device points inside `rect`'s outline) shaded between its
    /// stops: a strip of quads from each stop's outline to the next one's,
    /// each vertex in its stop's colour, then the last stop's colour to the
    /// centre; one geometry call.
    private func shadeProfile(_ rect: CGRect, radii: CornerRadii, stops: [WatchCaseDrawing.Stop], _ l: ViewerLayout) {
        guard stops.count >= 2 else { return }
        let rings = stops.map { st in WatchCaseDrawing.outline(rect, radii: radii, inset: st.inset).map { windowPoint($0, l) } }
        let n = rings[0].count
        var verts: [SDLVertex] = []
        var idx: [Int32] = []
        for (ring, st) in zip(rings, stops) {
            let c = WatchCaseDrawing.colour([st], at: 0)
            for p in ring {
                verts.append(SDLVertex(x: Float(p.0 + origin.x), y: Float(p.1 + origin.y), r: Float(c.r), g: Float(c.g), b: Float(c.b),
                                       a: Float(c.a), u: 0, v: 0))
            }
        }
        for k in 0..<(rings.count - 1) {
            let a = Int32(k * n), b = Int32((k + 1) * n)
            for i in 0..<Int32(n) {
                let j = (i + 1) % Int32(n)
                idx += [a + i, a + j, b + j, a + i, b + j, b + i]
            }
        }
        // The innermost outline, filled as a fan (it is convex).
        let last = Int32((rings.count - 1) * n)
        for i in 1..<Int32(n - 1) { idx += [last, last + i, last + i + 1] }
        let count = Int32(verts.count)
        _ = verts.withUnsafeMutableBytes { v in
            idx.withUnsafeBufferPointer { sdl.RenderGeometry(renderer, nil, v.baseAddress!, count, $0.baseAddress, Int32(idx.count)) }
        }
    }

    private func captureNow() {
        let jobs = pendingCaptures
        pendingCaptures.removeAll()
        var ok = false
        var png: [UInt8]?
        if let s = sdl.RenderReadPixels(renderer, nil) {
            if let c = sdl.ConvertSurface(s, SDLConst.pixelFormatXRGB8888) {
                let i = SDL.surfaceInfo(c)
                if let p = i.pixels { png = PNGWriter.encode(rgba: PNGWriter.rgba(fromBGRX: p, width: i.w, height: i.h, bytesPerRow: i.pitch), width: i.w, height: i.h) }
                sdl.DestroySurface(c)
            }
            sdl.DestroySurface(s)
        }
        for (path, done) in jobs {
            if let png { ok = (try? Data(png).write(to: URL(fileURLWithPath: path))) != nil }
            done(ok)
        }
    }
}

/// Screenshot file names ("<device> <date at time>.png").
public enum DeviceCaptureFileName {
    public static func screenshot(device: String, at date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "\(device.replacingOccurrences(of: "/", with: "-")) \(f.string(from: date)).png"
    }
}
