import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

// The platform layer's interfaces (round R7, 09-open-design.md §2 `OVPlatform`
// and §4): a back end creates windows and delivers events; windows take
// frames and expose what a compositor needs. Two back ends exist: SDL3
// (X11 and Wayland; `SDLBackend`) and an in-memory one for tests
// (`HeadlessBackend`).

/// How a window should be created.
public struct WindowConfiguration: Sendable, Equatable {
    public var title: String
    /// Content size in points.
    public var size: CGSize
    public var resizable: Bool
    /// The window will be drawn through Vulkan (the compositor's surface);
    /// otherwise frames arrive as pixel buffers (`PlatformWindow.present`).
    public var vulkan: Bool
    /// Ask for a back buffer at the display's pixel density.
    public var highPixelDensity: Bool
    /// A pop-up menu window of this window (R8): no decorations, positioned
    /// at `popupOrigin` (points from the parent's top-left corner), above the
    /// parent; the window system may move it to keep it on screen.
    public var popupParent: PlatformWindowID?
    public var popupOrigin: CGPoint
    /// The window system draws the window's title bar and frame (true), or
    /// the app draws its own: no title bar or frame from the window system;
    /// the app's hit test (`PlatformWindow.setHitTest`) says where the
    /// window moves and resizes (client-side decorations, B5-OPENVIEWS).
    public var decorated: Bool

    public init(title: String = "", size: CGSize = CGSize(width: 800, height: 600), resizable: Bool = true,
                vulkan: Bool = false, highPixelDensity: Bool = true, popupParent: PlatformWindowID? = nil,
                popupOrigin: CGPoint = .zero, decorated: Bool = true) {
        self.title = title
        self.size = size
        self.resizable = resizable
        self.vulkan = vulkan
        self.highPixelDensity = highPixelDensity
        self.popupParent = popupParent
        self.popupOrigin = popupOrigin
        self.decorated = decorated
    }
}

/// What a point of an undecorated window is for (the window system moves or
/// resizes the window when a press lands on a draggable or resize region).
public enum WindowHitRegion: Sendable, Equatable {
    case normal, draggable
    case resizeTopLeft, resizeTop, resizeTopRight, resizeRight, resizeBottomRight, resizeBottom, resizeBottomLeft,
         resizeLeft
}

/// Text on the system clipboard.
@MainActor
public protocol PlatformClipboard: AnyObject {
    var text: String? { get set }
    var hasText: Bool { get }
}

/// What a Vulkan compositor needs from a window (the compositor itself is
/// round R5's): the instance extensions required to present to this
/// window system, and surface creation for an instance the compositor made.
@MainActor
public protocol PlatformVulkanSurface: AnyObject {
    /// Instance extensions needed to create a surface for this window.
    func requiredInstanceExtensions() -> [String]
    /// The `vkGetInstanceProcAddr` of the Vulkan loader the window system uses.
    var instanceProcAddress: UnsafeMutableRawPointer? { get }
    /// Creates a `VkSurfaceKHR` for this window (`instance` is a `VkInstance`;
    /// the result is the surface handle as a 64-bit value). Throws when the
    /// window system refuses.
    func createSurface(instance: UnsafeMutableRawPointer) throws -> UInt64
    func destroySurface(_ surface: UInt64, instance: UnsafeMutableRawPointer)
    /// Creates an instance and a surface, asks every device whether it can
    /// present to it, and tears both down: a self-test of the surface path.
    func probe() -> VulkanProbeResult
}

/// The outcome of `PlatformVulkanSurface.probe()`.
public struct VulkanProbeResult: Sendable, Equatable {
    /// Devices with a queue family that can present to the window.
    public var presentingDevices: Int
    public var report: String
    public init(presentingDevices: Int, report: String) {
        self.presentingDevices = presentingDevices
        self.report = report
    }
}

/// A window of a back end.
@MainActor
public protocol PlatformWindow: AnyObject {
    var id: PlatformWindowID { get }
    var title: String { get set }
    /// Content size in points.
    var size: CGSize { get }
    /// Back-buffer size in pixels.
    var pixelSize: (width: Int, height: Int) { get }
    /// Pixels per point.
    var scale: Double { get }
    /// The refresh rate of the display the window is on (Hz).
    var refreshRate: Double { get }
    var isClosed: Bool { get }
    func setSize(_ size: CGSize)
    /// Shows a frame drawn in software (pixel size should be `pixelSize`).
    func present(_ frame: PixelBuffer)
    /// Reads back what the window last showed (the window surface after
    /// `present`), or nil when the back end cannot.
    func readback() -> PixelBuffer?
    /// Starts delivering text input (and input-method composition) for a
    /// text field whose caret is at `caretRect` (points).
    func startTextInput(caretRect: CGRect)
    func stopTextInput()
    var isTextInputActive: Bool { get }
    /// The Vulkan surface interface, for windows created with `vulkan: true`.
    var vulkan: (any PlatformVulkanSurface)? { get }
    /// The window this pop-up belongs to (nil: a top-level window).
    var popupParent: PlatformWindowID? { get }
    /// Raises the window and gives it keyboard focus (after a pop-up of it
    /// closes: without a window manager the focus would stay nowhere).
    func activate()
    /// Minimises the window (R11: Window > Minimize).
    func minimize()
    func close()
    /// The window's top-left corner on the screen in pixels, when the
    /// window system tells (accessibility extents in screen coordinates).
    var screenOrigin: CGPoint? { get }
}

extension PlatformWindow {
    public var screenOrigin: CGPoint? { nil }
}

/// The window-state operations of client-side decorations (the close,
/// minimize and zoom buttons an app draws; B5-OPENVIEWS). Windows that do
/// not adopt it are decorated by their window system.
@MainActor
public protocol PlatformWindowDecorations: AnyObject {
    /// False when the window was created without the window system's title
    /// bar and frame (`WindowConfiguration.decorated`).
    var isDecorated: Bool { get }
    /// Asks `test` (points in the window) where presses move or resize the
    /// window; nil removes the test.
    func setHitTest(_ test: (@MainActor (CGPoint) -> WindowHitRegion)?)
    var isMaximized: Bool { get }
    var isFullscreen: Bool { get }
    func setMaximized(_ maximized: Bool)
    func setFullscreen(_ fullscreen: Bool)
}

/// A source of windows and events.
@MainActor
public protocol PlatformBackend: AnyObject {
    /// "sdl:x11", "sdl:wayland", "headless", …
    var name: String { get }
    /// Seconds on a monotonic clock.
    var now: TimeInterval { get }
    var clipboard: any PlatformClipboard { get }
    func makeWindow(_ configuration: WindowConfiguration) throws -> any PlatformWindow
    var windows: [any PlatformWindow] { get }
    /// Returns the pending events. With none pending, waits until an event
    /// arrives or until `deadline` (back-end time; nil waits for the next
    /// event); work queued on the main queue meanwhile is run.
    func waitForEvents(until deadline: TimeInterval?) -> [PlatformEvent]
    /// Queues a synthetic event that `waitForEvents` returns in order
    /// (SDL: pushed through SDL's event queue).
    func post(_ event: PlatformEvent)
    /// Hands a URL to the desktop (the default `openURL` action).
    func openExternally(_ url: URL) -> Bool
    /// The desktop settings (R10: appearance, contrast, text size,
    /// accessibility flags, locale); `.settingsChanged` reports changes.
    var settings: PlatformSettings { get }
    /// Releases the window system.
    func shutdown()
}

/// Errors of the platform layer.
public enum PlatformError: Error, CustomStringConvertible {
    case unavailable(String)
    case windowCreationFailed(String)
    case vulkan(String)

    public var description: String {
        switch self {
        case .unavailable(let s): return "platform unavailable: \(s)"
        case .windowCreationFailed(let s): return "window creation failed: \(s)"
        case .vulkan(let s): return "Vulkan: \(s)"
        }
    }
}

/// Picks the back end: `OV_PLATFORM=headless` or `sdl` forces one; otherwise
/// SDL when libSDL3 loads and a display is reachable, else headless.
@MainActor
public enum Platform {
    public static func makeDefaultBackend() -> any PlatformBackend {
        let choice = ProcessInfo.processInfo.environment["OV_PLATFORM"]?.lowercased()
        if choice == "headless" { return HeadlessBackend() }
        do {
            return try SDLBackend()
        } catch {
            if choice == "sdl" {
                FileHandle.standardError.write(Data("OVPlatform: \(error)\n".utf8))
            }
            return HeadlessBackend()
        }
    }
}
