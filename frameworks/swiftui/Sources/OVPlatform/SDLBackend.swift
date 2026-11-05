import COVSDL
import Dispatch
import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

// The SDL3 back end (09-open-design.md §4): windows on X11 or Wayland
// (whichever SDL picks; `SDL_VIDEO_DRIVER=x11|wayland` forces one), pointer,
// touch, wheel, keyboard, text input and input-method composition, the
// clipboard, a software frame path through the window surface, and the
// Vulkan surface interface for the compositor.
//
// Coordinates. SDL reports window coordinates; their relation to pixels
// depends on the window system (Wayland: logical units with a pixel density;
// X11: pixels with a content scale). OpenViews works in points: the window's
// display scale (pixels per point) is SDL's display scale, and window
// coordinates convert with density / scale.
//
// Sleeping. The window system's connection (the X11 or Wayland display's
// file descriptor) is watched by a dispatch source on the main queue, so the
// run loop can sleep in the main run loop and wake for either window-system
// input or main-queue work (main-actor tasks). Without that descriptor it
// polls in 10 ms slices.

/// The loaded SDL3 function table.
@MainActor
enum SDLLibrary {
    private static var cached: OVSDLAPI?

    static func load() throws -> OVSDLAPI {
        if let cached { return cached }
        var err = [CChar](repeating: 0, count: 512)
        guard let p = ov_sdl_load(nil, &err, err.count) else {
            throw PlatformError.unavailable(String(decoding: err.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
                                                   as: UTF8.self))
        }
        cached = p.pointee
        return p.pointee
    }

    static var loadedPath: String { String(cString: ov_sdl_loaded_path()) }
}

/// A window backed by an `SDL_Window`.
@MainActor
public final class SDLWindow: PlatformWindow {
    let sdl: OVSDLAPI
    let handle: OpaquePointer
    public let id: PlatformWindowID
    public private(set) var isClosed = false
    public private(set) var isTextInputActive = false
    public let vulkan: (any PlatformVulkanSurface)?
    public let popupParent: PlatformWindowID?
    private weak var backend: SDLBackend?

    init(sdl: OVSDLAPI, handle: OpaquePointer, vulkan: Bool, backend: SDLBackend, popupParent: PlatformWindowID? = nil) {
        self.sdl = sdl
        self.handle = handle
        id = sdl.GetWindowID(handle)
        self.vulkan = vulkan ? SDLVulkanSurface(sdl: sdl, window: handle) : nil
        self.backend = backend
        self.popupParent = popupParent
    }

    /// The title last set (read by the AT-SPI export).
    private var storedTitle = ""

    func rememberTitle(_ t: String) { storedTitle = t }

    public var title: String {
        get { storedTitle }
        set {
            storedTitle = newValue
            _ = sdl.SetWindowTitle(handle, newValue)
        }
    }

    /// Window size in SDL window coordinates.
    var windowCoordinateSize: (Int32, Int32) {
        var w: Int32 = 0, h: Int32 = 0
        _ = sdl.GetWindowSize(handle, &w, &h)
        return (w, h)
    }

    public var pixelSize: (width: Int, height: Int) {
        var w: Int32 = 0, h: Int32 = 0
        _ = sdl.GetWindowSizeInPixels(handle, &w, &h)
        return (Int(w), Int(h))
    }

    public var scale: Double {
        let s = Double(sdl.GetWindowDisplayScale(handle))
        return s > 0 ? s : 1
    }

    /// Points per SDL window coordinate.
    var pointsPerCoordinate: Double {
        let (w, _) = windowCoordinateSize
        guard w > 0 else { return 1 }
        return Double(pixelSize.width) / Double(w) / scale
    }

    public var size: CGSize {
        let p = pixelSize, s = scale
        return CGSize(width: Double(p.width) / s, height: Double(p.height) / s)
    }

    public var refreshRate: Double {
        let display = sdl.GetDisplayForWindow(handle)
        if display != 0, let mode = sdl.GetCurrentDisplayMode(display), mode.pointee.refresh_rate > 1 {
            return Double(mode.pointee.refresh_rate)
        }
        return 60
    }

    public func setSize(_ size: CGSize) {
        let k = pointsPerCoordinate
        _ = sdl.SetWindowSize(handle, Int32((size.width / k).rounded()), Int32((size.height / k).rounded()))
    }

    public func minimize() {
        guard !isClosed else { return }
        _ = sdl.MinimizeWindow(handle)
    }

    /// SDL's window position (X11: screen pixels; Wayland gives none).
    public var screenOrigin: CGPoint? {
        guard !isClosed else { return nil }
        var x: Int32 = 0, y: Int32 = 0
        guard sdl.GetWindowPosition(handle, &x, &y) else { return nil }
        return CGPoint(x: Double(x), y: Double(y))
    }

    public func activate() {
        guard !isClosed else { return }
        _ = sdl.RaiseWindow(handle)
        var api = sdl
        _ = ov_sdl_x11_focus(&api, handle)
    }

    /// Shrinks the window to the usable area of its display and moves it
    /// inside (QA B5: a default size at scale 2 ran off the screen).
    func fitToDisplay() {
        let display = sdl.GetDisplayForWindow(handle)
        guard display != 0 else { return }
        var r = SDL_Rect()
        guard sdl.GetDisplayUsableBounds(display, &r), r.w > 0, r.h > 0 else { return }
        let (w, h) = windowCoordinateSize
        let nw = min(w, r.w), nh = min(h, r.h)
        guard nw != w || nh != h else { return }
        _ = sdl.SetWindowSize(handle, nw, nh)
        _ = sdl.SetWindowPosition(handle, r.x + (r.w - nw) / 2, r.y + (r.h - nh) / 2)
    }

    func toPoints(x: Float, y: Float) -> CGPoint {
        let k = pointsPerCoordinate
        return CGPoint(x: Double(x) * k, y: Double(y) * k)
    }

    func toCoordinates(_ p: CGPoint) -> (Float, Float) {
        let k = pointsPerCoordinate
        return (Float(p.x / k), Float(p.y / k))
    }

    public func present(_ frame: PixelBuffer) {
        guard !isClosed, let dst = sdl.GetWindowSurface(handle) else { return }
        var bytes = frame.bytes
        bytes.withUnsafeMutableBytes { raw in
            guard let src = sdl.CreateSurfaceFrom(Int32(frame.width), Int32(frame.height), SDL_PIXELFORMAT_RGBA32,
                                                  raw.baseAddress, Int32(frame.width * 4)) else { return }
            _ = sdl.BlitSurface(src, nil, dst, nil)
            sdl.DestroySurface(src)
        }
        _ = sdl.UpdateWindowSurface(handle)
    }

    public func readback() -> PixelBuffer? {
        guard !isClosed, let surface = sdl.GetWindowSurface(handle),
              let rgba = sdl.ConvertSurface(surface, SDL_PIXELFORMAT_RGBA32) else { return nil }
        defer { sdl.DestroySurface(rgba) }
        _ = sdl.LockSurface(rgba)
        defer { sdl.UnlockSurface(rgba) }
        let w = Int(rgba.pointee.w), h = Int(rgba.pointee.h), pitch = Int(rgba.pointee.pitch)
        guard let base = rgba.pointee.pixels?.assumingMemoryBound(to: UInt8.self) else { return nil }
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<(w * 4) { bytes[y * w * 4 + x] = base[y * pitch + x] }
        }
        return PixelBuffer(width: w, height: h, bytes: bytes)
    }

    public func startTextInput(caretRect: CGRect) {
        let (x, y) = toCoordinates(caretRect.origin)
        let (w, h) = toCoordinates(CGPoint(x: caretRect.width, y: caretRect.height))
        var r = SDL_Rect(x: Int32(x), y: Int32(y), w: max(1, Int32(w)), h: max(1, Int32(h)))
        _ = sdl.SetTextInputArea(handle, &r, 0)
        if !isTextInputActive { _ = sdl.StartTextInput(handle) }
        isTextInputActive = true
    }

    public func stopTextInput() {
        if isTextInputActive { _ = sdl.StopTextInput(handle) }
        isTextInputActive = false
    }

    /// The window system connection's descriptor, or -1.
    var displayFileDescriptor: Int32 {
        var api = sdl
        return ov_sdl_display_fd(&api, handle)
    }

    public func close() {
        guard !isClosed else { return }
        isClosed = true
        stopTextInput()
        sdl.DestroyWindow(handle)
        backend?.windowClosed(self)
    }
}

/// The Vulkan surface interface of an SDL window.
@MainActor
final class SDLVulkanSurface: PlatformVulkanSurface {
    let sdl: OVSDLAPI
    let window: OpaquePointer

    init(sdl: OVSDLAPI, window: OpaquePointer) {
        self.sdl = sdl
        self.window = window
    }

    func requiredInstanceExtensions() -> [String] {
        var n: UInt32 = 0
        guard let list = sdl.Vulkan_GetInstanceExtensions(&n) else { return [] }
        return (0..<Int(n)).compactMap { list[$0].map { String(cString: $0) } }
    }

    var instanceProcAddress: UnsafeMutableRawPointer? {
        unsafeBitCast(sdl.Vulkan_GetVkGetInstanceProcAddr(), to: UnsafeMutableRawPointer?.self)
    }

    func createSurface(instance: UnsafeMutableRawPointer) throws -> UInt64 {
        var surface: VkSurfaceKHR?
        guard sdl.Vulkan_CreateSurface(window, OpaquePointer(instance), nil, &surface), let surface else {
            throw PlatformError.vulkan((sdl.GetError().map { String(cString: $0) } ?? ""))
        }
        return UInt64(UInt(bitPattern: UnsafeRawPointer(surface)))
    }

    func destroySurface(_ surface: UInt64, instance: UnsafeMutableRawPointer) {
        guard let p = UnsafeRawPointer(bitPattern: UInt(surface)) else { return }
        sdl.Vulkan_DestroySurface(OpaquePointer(instance), OpaquePointer(p), nil)
    }

    func probe() -> VulkanProbeResult {
        var report = [CChar](repeating: 0, count: 2048)
        var api = sdl
        let n = ov_vk_probe_surface(&api, window, &report, report.count)
        let text = String(decoding: report.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return VulkanProbeResult(presentingDevices: Int(n), report: text)
    }
}

/// Clipboard text through SDL.
@MainActor
final class SDLClipboard: PlatformClipboard {
    let sdl: OVSDLAPI
    init(sdl: OVSDLAPI) { self.sdl = sdl }

    var text: String? {
        get {
            guard sdl.HasClipboardText(), let p = sdl.GetClipboardText() else { return nil }
            defer { sdl.free(p) }
            return String(cString: p)
        }
        set { _ = sdl.SetClipboardText(newValue ?? "") }
    }

    var hasText: Bool { sdl.HasClipboardText() }
}

/// The SDL3 back end.
@MainActor
public final class SDLBackend: PlatformBackend {
    let sdl: OVSDLAPI
    public let name: String
    public let clipboard: any PlatformClipboard
    private var open: [SDLWindow] = []
    private let syntheticType: UInt32
    private var synthetic: [Int: PlatformEvent] = [:]
    /// Last size reported per window (SDL sends RESIZED and
    /// PIXEL_SIZE_CHANGED for one resize: report a size once).
    private var reportedSizes: [PlatformWindowID: CGSize] = [:]
    private var buttonFilter = MouseButtonFilter()
    /// SDL's mouse id for events synthesised from touches (`SDL_TOUCH_MOUSEID`).
    static let touchMouseID = UInt32.max
    private var syntheticSeq = 0
    private var displaySource: DispatchSourceRead?
    private var displaySourceSuspended = false
    private var keepAlive: Timer?

    /// Loads libSDL3 and initialises its video subsystem.
    public init() throws {
        let sdl = try SDLLibrary.load()
        self.sdl = sdl
        // Touches arrive as touches (no synthesized mouse events) and the
        // last window closing does not quit by itself (the app host decides).
        _ = sdl.SetHint("SDL_TOUCH_MOUSE_EVENTS", "0")
        _ = sdl.SetHint("SDL_MOUSE_TOUCH_EVENTS", "0")
        _ = sdl.SetHint("SDL_QUIT_ON_LAST_WINDOW_CLOSE", "0")
        _ = sdl.SetHint("SDL_APP_NAME", "OpenViews")
        // Text fields draw an input method's uncommitted text themselves
        // (marked text at the caret) and leave the candidate list to the
        // input method. Without this, SDL's X11 driver asks XIM for no
        // composition events and the text being composed shows only in the
        // input method's own window (issue 23).
        _ = sdl.SetHint("SDL_IME_IMPLEMENTED_UI", "composition")
        guard sdl.Init(UInt32(SDL_INIT_VIDEO)) else {
            throw PlatformError.unavailable((sdl.GetError().map { String(cString: $0) } ?? ""))
        }
        let driver = sdl.GetCurrentVideoDriver().map { String(cString: $0) } ?? "unknown"
        name = "sdl:\(driver)"
        // X11 has a native software framebuffer (shared-memory images); without
        // this hint SDL may route window surfaces through an OpenGL renderer
        // and re-create the window to do so (a hide/show at start-up).
        if driver == "x11" { _ = sdl.SetHint("SDL_FRAMEBUFFER_ACCELERATION", "0") }
        clipboard = SDLClipboard(sdl: sdl)
        syntheticType = sdl.RegisterEvents(1)
        // R10: desktop settings (environment, settings file, portal, SDL's
        // system theme); changes arrive as `.settingsChanged`.
        let reader = DesktopSettingsReader()
        settingsReader = reader
        reader.systemDark = Self.theme(sdl.GetSystemTheme())
        reader.onChange = { [weak self] _ in self?.post(.settingsChanged) }
    }

    private var settingsReader: DesktopSettingsReader?

    public var settings: PlatformSettings { settingsReader?.current ?? PlatformSettings() }

    /// Where the settings came from (diagnostics).
    public var settingsSources: [String] { settingsReader?.sources ?? [] }

    private static func theme(_ t: SDL_SystemTheme) -> Bool? {
        switch t {
        case SDL_SYSTEM_THEME_DARK: return true
        case SDL_SYSTEM_THEME_LIGHT: return false
        default: return nil
        }
    }

    /// The SDL version that was loaded, as "major.minor.micro", and its file.
    public var libraryDescription: String {
        let v = Int(sdl.GetVersion())
        return "\(v / 1_000_000).\((v / 1_000) % 1_000).\(v % 1_000) (\(SDLLibrary.loadedPath))"
    }

    public var now: TimeInterval { Double(sdl.GetTicksNS()) / 1e9 }

    public var windows: [any PlatformWindow] { open }

    private var vulkanLoaded = false

    public func makeWindow(_ configuration: WindowConfiguration) throws -> any PlatformWindow {
        if configuration.vulkan && !vulkanLoaded {
            // The compositor and SDL must use the same Vulkan loader
            // (09-open-design.md §3.6): YCODE_VULKAN_LIBRARY names it, else the
            // system's default.
            let path = ProcessInfo.processInfo.environment["YCODE_VULKAN_LIBRARY"]
            if !sdl.Vulkan_LoadLibrary(path) {
                throw PlatformError.vulkan(sdl.GetError().map { String(cString: $0) } ?? "no Vulkan loader")
            }
            vulkanLoaded = true
        }
        if let parentID = configuration.popupParent {
            // A pop-up menu (SDL_CreatePopupWindow): offsets and size in the
            // parent's window coordinates.
            guard let parent = window(parentID) else { throw PlatformError.windowCreationFailed("no parent window") }
            let k = parent.pointsPerCoordinate
            // Not focusable: the parent keeps the keyboard and the host
            // routes keys to its pop-ups (on X11 without a window manager the
            // focus otherwise fell to the root window when a pop-up closed).
            var pflags = OV_SDL_WINDOW_POPUP_MENU | OV_SDL_WINDOW_NOT_FOCUSABLE
            if configuration.highPixelDensity { pflags |= OV_SDL_WINDOW_HIGH_PIXEL_DENSITY }
            guard let h = sdl.CreatePopupWindow(parent.handle, Int32((configuration.popupOrigin.x / k).rounded()),
                                                Int32((configuration.popupOrigin.y / k).rounded()),
                                                Int32((configuration.size.width / k).rounded()),
                                                Int32((configuration.size.height / k).rounded()), pflags) else {
                throw PlatformError.windowCreationFailed((sdl.GetError().map { String(cString: $0) } ?? ""))
            }
            let w = SDLWindow(sdl: sdl, handle: h, vulkan: false, backend: self, popupParent: parentID)
            _ = sdl.ShowWindow(h)
            open.append(w)
            return w
        }
        var flags: UInt64 = 0
        if configuration.resizable { flags |= OV_SDL_WINDOW_RESIZABLE }
        if configuration.highPixelDensity { flags |= OV_SDL_WINDOW_HIGH_PIXEL_DENSITY }
        if configuration.vulkan { flags |= OV_SDL_WINDOW_VULKAN }
        guard let h = sdl.CreateWindow(configuration.title, Int32(configuration.size.width),
                                       Int32(configuration.size.height), flags) else {
            throw PlatformError.windowCreationFailed((sdl.GetError().map { String(cString: $0) } ?? ""))
        }
        let w = SDLWindow(sdl: sdl, handle: h, vulkan: configuration.vulkan, backend: self)
        w.rememberTitle(configuration.title)
        // Window systems that measure windows in pixels (X11) get the size in
        // points scaled to the display.
        if abs(w.pointsPerCoordinate - 1) > 0.01 { w.setSize(configuration.size) }
        w.fitToDisplay()
        _ = sdl.ShowWindow(h)
        open.append(w)
        watchDisplay(of: w)
        return w
    }

    func windowClosed(_ w: SDLWindow) { open.removeAll { $0 === w } }

    private func window(_ id: UInt32) -> SDLWindow? { open.first { $0.id == id } }

    // MARK: Waiting

    private func watchDisplay(of w: SDLWindow) {
        guard displaySource == nil else { return }
        let fd = w.displayFileDescriptor
        guard fd >= 0 else { return }
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                // Wake the run loop; SDL reads the connection when the loop
                // pumps. Suspended until then so a readable descriptor does
                // not fire again and again.
                guard let self, !self.displaySourceSuspended else { return }
                self.displaySourceSuspended = true
                self.displaySource?.suspend()
            }
        }
        source.resume()
        displaySource = source
        // Keeps the main run loop from reporting itself empty.
        let timer = Timer(timeInterval: 86_400, repeats: true) { _ in }
        RunLoop.main.add(timer, forMode: .default)
        keepAlive = timer
    }

    public func waitForEvents(until deadline: TimeInterval?) -> [PlatformEvent] {
        // Event times are when SDL read the events, not when they happened.
        // Events that queued while the app was busy (a long frame) all look
        // simultaneous: two quick clicks 0.1 ms apart. Times count as
        // reliable when the previous read was recent or the loop slept until
        // the events came; the duplicate-click filter compares only those.
        var out = drain(timesAreReliable: now - lastDrain < Self.busyGap)
        if !out.isEmpty { return out }
        let waitStart = now
        if displaySource != nil {
            let date = deadline.map { Date(timeIntervalSinceNow: max(0, $0 - now)) } ?? Date.distantFuture
            _ = RunLoop.main.run(mode: .default, before: date)
        } else {
            // No descriptor to watch: wait for SDL in slices, serving the main
            // queue between them.
            let remaining = deadline.map { max(0, $0 - now) } ?? 0.01
            _ = sdl.WaitEventTimeout(nil, Int32(min(10, max(0, remaining * 1_000)).rounded(.up)))
            _ = RunLoop.main.run(mode: .default, before: Date())
        }
        out = drain(timesAreReliable: now - waitStart > 0.001 || now - lastDrain < Self.busyGap)
        return out
    }

    /// Longer than this between two reads of the event queue, and the
    /// events read carry unreliable times.
    static let busyGap: TimeInterval = 0.02
    private var lastDrain: TimeInterval = 0
    private var eventTimesAreReliable = true

    private func drain(timesAreReliable: Bool) -> [PlatformEvent] {
        eventTimesAreReliable = timesAreReliable
        defer { lastDrain = now }
        var out: [PlatformEvent] = []
        sdl.PumpEvents()
        var e = SDL_Event()
        while sdl.PollEvent(&e) {
            if let p = translate(&e) { out.append(p) }
        }
        if displaySourceSuspended {
            displaySourceSuspended = false
            displaySource?.resume()
        }
        return out
    }

    // MARK: Translation

    private static func modifiers(_ m: UInt16) -> KeyModifiers {
        var r: KeyModifiers = []
        if m & UInt16(SDL_KMOD_SHIFT) != 0 { r.insert(.shift) }
        if m & UInt16(SDL_KMOD_CTRL) != 0 { r.insert(.control) }
        if m & UInt16(SDL_KMOD_ALT) != 0 { r.insert(.option) }
        if m & UInt16(SDL_KMOD_GUI) != 0 { r.insert(.command) }
        if m & UInt16(SDL_KMOD_CAPS) != 0 { r.insert(.capsLock) }
        return r
    }

    static func key(_ k: UInt32) -> Key {
        switch k {
        case UInt32(SDLK_RETURN), UInt32(SDLK_KP_ENTER): return .return
        case UInt32(SDLK_ESCAPE): return .escape
        case UInt32(SDLK_BACKSPACE): return .backspace
        case UInt32(SDLK_TAB): return .tab
        case UInt32(SDLK_SPACE): return .space
        case UInt32(SDLK_DELETE): return .deleteForward
        case UInt32(SDLK_LEFT): return .leftArrow
        case UInt32(SDLK_RIGHT): return .rightArrow
        case UInt32(SDLK_UP): return .upArrow
        case UInt32(SDLK_DOWN): return .downArrow
        case UInt32(SDLK_HOME): return .home
        case UInt32(SDLK_END): return .end
        case UInt32(SDLK_PAGEUP): return .pageUp
        case UInt32(SDLK_PAGEDOWN): return .pageDown
        case UInt32(SDLK_CLEAR): return .clear
        case UInt32(SDLK_F1)...UInt32(SDLK_F12): return .function(Int(k - UInt32(SDLK_F1)) + 1)
        default:
            if k < 0x4000_0000, let s = Unicode.Scalar(k) { return .character(Character(s)) }
            return .other(k)
        }
    }

    static func keycode(_ key: Key) -> UInt32 {
        switch key {
        case .character(let c): return c.unicodeScalars.first.map { $0.value } ?? 0
        case .return: return UInt32(SDLK_RETURN)
        case .escape: return UInt32(SDLK_ESCAPE)
        case .backspace: return UInt32(SDLK_BACKSPACE)
        case .tab: return UInt32(SDLK_TAB)
        case .space: return UInt32(SDLK_SPACE)
        case .deleteForward: return UInt32(SDLK_DELETE)
        case .leftArrow: return UInt32(SDLK_LEFT)
        case .rightArrow: return UInt32(SDLK_RIGHT)
        case .upArrow: return UInt32(SDLK_UP)
        case .downArrow: return UInt32(SDLK_DOWN)
        case .home: return UInt32(SDLK_HOME)
        case .end: return UInt32(SDLK_END)
        case .pageUp: return UInt32(SDLK_PAGEUP)
        case .pageDown: return UInt32(SDLK_PAGEDOWN)
        case .clear: return UInt32(SDLK_CLEAR)
        case .function(let n): return UInt32(SDLK_F1) + UInt32(max(0, n - 1))
        case .other(let k): return k
        }
    }

    private static func string(_ p: UnsafePointer<CChar>?) -> String { p.map { String(cString: $0) } ?? "" }

    func acceptButton(_ button: UInt8, down: Bool, t: Double, x: Float, y: Float) -> Bool {
        buttonFilter.accept(button: button, down: down, time: t, x: Double(x), y: Double(y), timeIsReliable: eventTimesAreReliable)
    }

    /// The modifier keys held at the last key event.
    private var heldModifiers: KeyModifiers = []

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    private func translate(_ e: inout SDL_Event) -> PlatformEvent? {
        let type = e.type
        let t = Double(e.common.timestamp) / 1e9
        switch type {
        case SDL_EVENT_QUIT.rawValue:
            return .quit
        case SDL_EVENT_SYSTEM_THEME_CHANGED.rawValue:
            settingsReader?.systemDark = Self.theme(sdl.GetSystemTheme())
            return nil
        case SDL_EVENT_WINDOW_SHOWN.rawValue: return .window(e.window.windowID, .shown)
        case SDL_EVENT_WINDOW_HIDDEN.rawValue: return .window(e.window.windowID, .hidden)
        case SDL_EVENT_WINDOW_MINIMIZED.rawValue: return .window(e.window.windowID, .minimized)
        case SDL_EVENT_WINDOW_RESTORED.rawValue: return .window(e.window.windowID, .restored)
        case SDL_EVENT_WINDOW_EXPOSED.rawValue: return .window(e.window.windowID, .exposed)
        case SDL_EVENT_WINDOW_FOCUS_GAINED.rawValue: return .window(e.window.windowID, .focusGained)
        case SDL_EVENT_WINDOW_FOCUS_LOST.rawValue: return .window(e.window.windowID, .focusLost)
        case SDL_EVENT_WINDOW_CLOSE_REQUESTED.rawValue: return .window(e.window.windowID, .closeRequested)
        case SDL_EVENT_WINDOW_MOUSE_LEAVE.rawValue: return .window(e.window.windowID, .pointerLeft)
        case SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED.rawValue, SDL_EVENT_WINDOW_RESIZED.rawValue:
            guard let w = window(e.window.windowID) else { return nil }
            let size = w.size
            if reportedSizes[w.id] == size { return nil }
            reportedSizes[w.id] = size
            return .window(w.id, .resized(size))
        case SDL_EVENT_WINDOW_DISPLAY_SCALE_CHANGED.rawValue:
            guard let w = window(e.window.windowID) else { return nil }
            return .window(w.id, .scaleChanged(w.scale))
        case SDL_EVENT_KEY_DOWN.rawValue, SDL_EVENT_KEY_UP.rawValue:
            // SDL's pointer events carry no modifiers: the keyboard's last state
            // goes with them (shift-click).
            heldModifiers = Self.modifiers(e.key.mod)
            return .key(KeyEvent(window: e.key.windowID, key: Self.key(e.key.key), isDown: e.key.down,
                                 isRepeat: e.key.repeat, modifiers: Self.modifiers(e.key.mod), timestamp: t))
        case SDL_EVENT_TEXT_INPUT.rawValue:
            return .textInput(TextInputEvent(window: e.text.windowID, text: Self.string(e.text.text), timestamp: t))
        case SDL_EVENT_TEXT_EDITING.rawValue:
            return .textEditing(TextEditingEvent(window: e.edit.windowID, text: Self.string(e.edit.text),
                                                 cursor: Int(e.edit.start), selectionLength: Int(e.edit.length),
                                                 timestamp: t))
        case SDL_EVENT_MOUSE_MOTION.rawValue:
            // Touches arrive as finger events; skip SDL's mouse copies.
            guard e.motion.which != Self.touchMouseID, let w = window(e.motion.windowID) else { return nil }
            let pressed = e.motion.state & 1 != 0
            return .pointer(PointerEvent(window: w.id, pointer: 0, kind: .mouse, phase: .moved,
                                         location: w.toPoints(x: e.motion.x, y: e.motion.y),
                                         button: pressed ? 1 : 0, isPressed: pressed, modifiers: heldModifiers, timestamp: t))
        case SDL_EVENT_MOUSE_BUTTON_DOWN.rawValue, SDL_EVENT_MOUSE_BUTTON_UP.rawValue:
            guard e.button.which != Self.touchMouseID, let w = window(e.button.windowID) else { return nil }
            guard acceptButton(e.button.button, down: e.button.down, t: t, x: e.button.x, y: e.button.y) else { return nil }
            return .pointer(PointerEvent(window: w.id, pointer: 0, kind: .mouse, phase: e.button.down ? .down : .up,
                                         location: w.toPoints(x: e.button.x, y: e.button.y),
                                         button: Int(e.button.button), isPressed: e.button.down, modifiers: heldModifiers, timestamp: t))
        case SDL_EVENT_MOUSE_WHEEL.rawValue:
            guard let w = window(e.wheel.windowID) else { return nil }
            var dx = Double(e.wheel.x), dy = Double(e.wheel.y)
            if e.wheel.direction == SDL_MOUSEWHEEL_FLIPPED {
                dx = -dx
                dy = -dy
            }
            let precise = dx.rounded() != dx || dy.rounded() != dy
            // A wheel notch scrolls 10 points (our choice; open in 06 §3).
            return .scroll(ScrollEvent(window: w.id, location: w.toPoints(x: e.wheel.mouse_x, y: e.wheel.mouse_y),
                                       delta: CGSize(width: dx * 10, height: dy * 10), isPrecise: precise,
                                       timestamp: t))
        case SDL_EVENT_FINGER_DOWN.rawValue, SDL_EVENT_FINGER_MOTION.rawValue, SDL_EVENT_FINGER_UP.rawValue,
             SDL_EVENT_FINGER_CANCELED.rawValue:
            guard let w = window(e.tfinger.windowID) else { return nil }
            let phase: PointerPhase
            switch type {
            case SDL_EVENT_FINGER_DOWN.rawValue: phase = .down
            case SDL_EVENT_FINGER_MOTION.rawValue: phase = .moved
            case SDL_EVENT_FINGER_UP.rawValue: phase = .up
            default: phase = .cancelled
            }
            let s = w.size
            let id = Int(truncatingIfNeeded: e.tfinger.fingerID) &+ 1
            return .pointer(PointerEvent(window: w.id, pointer: id == 0 ? 1 : id, kind: .touch, phase: phase,
                                         location: CGPoint(x: Double(e.tfinger.x) * s.width,
                                                           y: Double(e.tfinger.y) * s.height),
                                         button: 1, isPressed: phase == .down || phase == .moved, timestamp: t))
        case syntheticType:
            return synthetic.removeValue(forKey: Int(e.user.code))
        default:
            return nil
        }
    }

    // MARK: Synthetic events

    /// Mouse and key events go through SDL's queue as SDL events (and so
    /// through the translation above); the others as user events.
    public func post(_ event: PlatformEvent) {
        var e = SDL_Event()
        let ts = sdl.GetTicksNS()
        switch event {
        case .pointer(let p) where p.kind == .mouse:
            guard let w = window(p.window) else { return }
            let (x, y) = w.toCoordinates(p.location)
            switch p.phase {
            case .down, .up:
                e.type = (p.phase == .down ? SDL_EVENT_MOUSE_BUTTON_DOWN : SDL_EVENT_MOUSE_BUTTON_UP).rawValue
                e.button.timestamp = ts
                e.button.windowID = w.id
                e.button.button = UInt8(max(1, p.button))
                e.button.down = p.phase == .down
                e.button.clicks = 1
                e.button.x = x
                e.button.y = y
            case .moved, .cancelled:
                e.type = SDL_EVENT_MOUSE_MOTION.rawValue
                e.motion.timestamp = ts
                e.motion.windowID = w.id
                e.motion.state = p.isPressed ? 1 : 0
                e.motion.x = x
                e.motion.y = y
            }
        case .key(let k):
            e.type = (k.isDown ? SDL_EVENT_KEY_DOWN : SDL_EVENT_KEY_UP).rawValue
            e.key.timestamp = ts
            e.key.windowID = k.window
            e.key.key = Self.keycode(k.key)
            e.key.down = k.isDown
            e.key.repeat = k.isRepeat
            var mod: UInt16 = 0
            if k.modifiers.contains(.shift) { mod |= UInt16(SDL_KMOD_LSHIFT) }
            if k.modifiers.contains(.control) { mod |= UInt16(SDL_KMOD_LCTRL) }
            if k.modifiers.contains(.option) { mod |= UInt16(SDL_KMOD_LALT) }
            if k.modifiers.contains(.command) { mod |= UInt16(SDL_KMOD_LGUI) }
            e.key.mod = mod
        default:
            syntheticSeq += 1
            synthetic[syntheticSeq] = event
            e.type = syntheticType
            e.user.timestamp = ts
            e.user.code = Int32(syntheticSeq)
        }
        _ = sdl.PushEvent(&e)
    }

    public func openExternally(_ url: URL) -> Bool { sdl.OpenURL(url.absoluteString) }

    public func shutdown() {
        settingsReader?.stop()
        for w in open { w.close() }
        displaySource?.cancel()
        if displaySourceSuspended { displaySource?.resume() }
        displaySource = nil
        keepAlive?.invalidate()
        // With a Vulkan loader in the process, leave SDL (and its X11 or
        // Wayland connection) up: a vendor driver's exit handler still talks
        // to the display after this (the NVIDIA GLX library aborted with
        // "buffer overflow detected" in xcb once SDL_Quit had closed it).
        if !vulkanLoaded { sdl.Quit() }
    }
}

/// Drops duplicate mouse button events: a press of a button that is already
/// down, and a press (with its release) that follows a release of the same
/// button at the same place within `duplicateInterval` (QA B4: SDL 3.4.18 on
/// some X servers delivers one click as two press/release pairs 0.1–0.3 ms
/// apart; no person clicks twice within 4 ms). Only events whose times are
/// reliable are compared: events read late (after a long frame) all carry
/// about the same time, and a quick double click would lose its second click.
public struct MouseButtonFilter: Sendable {
    public static let duplicateInterval = 0.004
    private var down: Set<UInt8> = []
    private var lastRelease: [UInt8: (t: Double, x: Double, y: Double)] = [:]
    private var dropped: Set<UInt8> = []

    public init() {}

    /// Whether to deliver the event.
    public mutating func accept(button: UInt8, down isDown: Bool, time t: Double, x: Double, y: Double,
                                timeIsReliable: Bool = true) -> Bool {
        if isDown {
            if down.contains(button) { return false }
            if timeIsReliable, let r = lastRelease[button], t - r.t >= 0, t - r.t < Self.duplicateInterval, abs(r.x - x) < 1, abs(r.y - y) < 1 {
                dropped.insert(button)
                return false
            }
            down.insert(button)
            return true
        }
        if dropped.remove(button) != nil { return false }
        // A release without a press we saw (pressed outside) passes through.
        guard down.remove(button) != nil else { return true }
        lastRelease[button] = (t, x, y)
        return true
    }
}
