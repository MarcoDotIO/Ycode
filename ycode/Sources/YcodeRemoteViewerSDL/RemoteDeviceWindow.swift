// The Linux device window (display-stream.md §13): an SDL 3 window with the
// device in Ycode's frame (DeviceFrameGeometry), the stream image in its
// screen, a control row (Home, Lock, Volume, Rotate, Screenshot, the scale
// mode) and an optional status line; mouse → touches, keys → HID usages,
// the frame's buttons clickable, the wheel a drag (a watch's crown). The
// renderer presents without vsync, as soon as a frame is decoded; only the
// rectangle the frame changed is uploaded to the texture.
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
    public var showStatus = false
    /// Where screenshots go (Ctrl+Shift+S, the control row).
    public var captureDirectory: URL
    public var log: (String) -> Void = { print($0) }
    public var onClose: () -> Void = {}

    private var window: UnsafeMutableRawPointer!
    private var renderer: UnsafeMutableRawPointer!
    private var texture: UnsafeMutableRawPointer?
    private var textureSize = (0, 0)
    private var textureCanvas: ObjectIdentifier?
    private var textureFormat: UInt32 = 0
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

    public struct Control {
        public var title: String
        public var action: () -> Void
    }

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

    private func updateWindowMetrics() {
        var w: Int32 = 0, h: Int32 = 0, pw: Int32 = 0, ph: Int32 = 0
        _ = sdl.GetWindowSize(window, &w, &h)
        _ = sdl.GetWindowSizeInPixels(window, &pw, &ph)
        session.windowWidth = Double(w)
        session.windowHeight = Double(h)
        session.pixelDensity = w > 0 ? Double(pw) / Double(w) : 1
        // Render in window units (SDL scales to pixels).
        _ = sdl.SetRenderScale(renderer, Float(session.pixelDensity), Float(session.pixelDensity))
        needsRedraw = true
    }

    /// Resizes the window to show the device at the current scale mode's size.
    public func fitWindowToDevice(scale: Double) {
        let s = ViewerLayout.windowSize(geometry: session.geometry, scale: scale)
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
            if session.title != lastTitle {
                lastTitle = session.title
                _ = sdl.SetWindowTitle(window, lastTitle)
                needsRedraw = true
            }
            if needsRedraw { draw() }
        }
        session.cancelInput()
        if let texture { sdl.DestroyTexture(texture) }
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
            let (x, y) = (Double(e.buttonX), Double(e.buttonY))
            lastMouse = (x, y)
            if let c = control(at: x, y) { c.action(); needsRedraw = true; return }
            buttonDown = true
            let mod = sdl.GetModState()
            session.pointerDown(x: x, y: y, multiTouch: mod & SDLConst.kmodAlt != 0, shift: mod & SDLConst.kmodShift != 0,
                                control: mod & SDLConst.kmodCtrl != 0)
            needsRedraw = true
        case SDLConst.mouseMotion:
            let (x, y) = (Double(e.motionX), Double(e.motionY))
            lastMouse = (x, y)
            let mod = sdl.GetModState()
            session.pointerMoved(x: x, y: y, multiTouch: mod & SDLConst.kmodAlt != 0, shift: mod & SDLConst.kmodShift != 0)
            needsRedraw = true
        case SDLConst.mouseButtonUp where e.buttonIndex == 1:
            buttonDown = false
            session.pointerUp(x: Double(e.buttonX), y: Double(e.buttonY))
            needsRedraw = true
        case SDLConst.mouseWheel:
            let flip: Float = e.wheelFlipped ? -1 : 1
            session.wheel(x: Double(e.wheelMouseX), y: Double(e.wheelMouseY), dx: Double(e.wheelX * flip), dy: Double(e.wheelY * flip),
                          now: Double(viewerNanoseconds()) / 1e9, alt: sdl.GetModState() & SDLConst.kmodAlt != 0)
        case SDLConst.windowMouseLeave:
            session.multiTouchHover = nil
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
        // Ctrl itself stays with the window.
        if sc == 0xE0 || sc == 0xE4 { return }
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

    // MARK: Controls

    public var controls: [Control] {
        var c = session.controlButtons.map { item in Control(title: item.title) { [session] in session.press(item.button) } }
        // A Vision Pro has no rotation; its camera resets instead (visionos.md §5.5.8).
        c += [session.isSpatial ? Control(title: "Reset Camera") { [session] in session.resetCamera() }
                  : Control(title: "Rotate") { [session] in session.rotate(left: true) },
              Control(title: "Shot") { [weak self] in self?.screenshot() },
              Control(title: session.audio == nil ? "No sound" : session.audio!.muted ? "Unmute" : "Mute") { [weak self] in self?.toggleMute() },
              Control(title: session.scaleMode == .fit ? "Fit" : session.scaleMode == .point ? "1:1 pt" : "1:1 px") { [weak self] in
                  guard let self else { return }
                  let all = ViewerScaleMode.allCases
                  self.setScale(all[(all.firstIndex(of: self.session.scaleMode)! + 1) % all.count])
              }]
        return c
    }

    private func controlRects() -> [(ViewerRect, Control)] {
        let cs = controls
        let h = 24.0, gap = 6.0
        let widths = cs.map { Double($0.title.count) * 8 + 16 }
        let total = widths.reduce(0, +) + gap * Double(cs.count - 1)
        var x = max(4, (session.windowWidth - total) / 2)
        let y = session.windowHeight - ViewerLayout.controlBar + (ViewerLayout.controlBar - h) / 2
        var out: [(ViewerRect, Control)] = []
        for (i, c) in cs.enumerated() {
            out.append((ViewerRect(x: x, y: y, width: widths[i], height: h), c))
            x += widths[i] + gap
        }
        return out
    }

    private func control(at x: Double, _ y: Double) -> Control? { controlRects().first { $0.0.contains(x, y) }?.1 }

    // MARK: Drawing

    private func color(_ r: UInt8, _ g: UInt8, _ b: UInt8, _ a: UInt8 = 255) { _ = sdl.SetRenderDrawColor(renderer, r, g, b, a) }

    private func fill(_ r: ViewerRect) {
        var f = SDLFRect(x: Float(r.x), y: Float(r.y), w: Float(r.width), h: Float(r.height))
        _ = sdl.RenderFillRect(renderer, &f)
    }

    /// A filled polygon (a fan around its first point; the shapes are convex).
    private func polygon(_ pts: [(Double, Double)], _ c: (Float, Float, Float, Float)) {
        guard pts.count >= 3 else { return }
        var verts = pts.map { SDLVertex(x: Float($0.0), y: Float($0.1), r: c.0, g: c.1, b: c.2, a: c.3, u: 0, v: 0) }
        var idx: [Int32] = []
        for i in 1..<(pts.count - 1) { idx += [0, Int32(i), Int32(i + 1)] }
        _ = verts.withUnsafeMutableBytes { v in idx.withUnsafeBufferPointer { sdl.RenderGeometry(renderer, nil, v.baseAddress!, Int32(pts.count), $0.baseAddress, Int32(idx.count)) } }
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
            return SDLVertex(x: Float(p.0), y: Float(p.1), r: 1, g: 1, b: 1, a: 1, u: Float(tu), v: Float(tv))
        }
        var idx: [Int32] = []
        for i in 1..<(pts.count - 1) { idx += [0, Int32(i), Int32(i + 1)] }
        _ = verts.withUnsafeMutableBytes { v in idx.withUnsafeBufferPointer { sdl.RenderGeometry(renderer, texture, v.baseAddress!, Int32(pts.count), $0.baseAddress, Int32(idx.count)) } }
    }

    private func text(_ s: String, x: Double, y: Double, scale: Float = 1) {
        if scale != 1 { _ = sdl.SetRenderScale(renderer, scale * Float(session.pixelDensity), scale * Float(session.pixelDensity)) }
        _ = sdl.RenderDebugText(renderer, Float(x) / scale, Float(y) / scale, s)
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
        let l = session.layout
        let g = l.geometry
        let bg: (UInt8, UInt8, UInt8) = (0x1E, 0x1F, 0x22)
        color(bg.0, bg.1, bg.2)
        _ = sdl.RenderClear(renderer)
        let body = l.window(g.body), screen = l.screen
        let framed = session.bezels && session.spec.hasFrame
        if framed {
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
        for (r, c) in controlRects() {
            color(0x3A, 0x3B, 0x40)
            fill(r)
            color(0xE8, 0xE8, 0xEC)
            text(c.title, x: r.x + 8, y: r.y + 8)
        }
        if showStatus {
            color(0, 0, 0, 160)
            fill(ViewerRect(x: 0, y: 0, width: session.windowWidth, height: 14))
            color(0x9F, 0xE8, 0x9F)
            text(session.statusText, x: 4, y: 3)
        }
        if let n = session.notice {
            color(0, 0, 0, 180)
            let w = Double(n.text.count) * 8 + 12
            fill(ViewerRect(x: (session.windowWidth - w) / 2, y: 20, width: w, height: 18))
            color(0xFF, 0xFF, 0xFF)
            text(n.text, x: (session.windowWidth - w) / 2 + 6, y: 25)
        }
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
