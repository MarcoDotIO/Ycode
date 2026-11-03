// The compositor's surface interface: the boundary between rendering
// (OVRender, round R5) and the platform host (OVPlatform, round R7).
// 09-open-design.md §3.6 records the agreement.
//
// The platform host owns windows, the run loop and input. For each window it
// implements `RenderSurface` and asks `makeCompositor(for:)` for a
// compositor. Once per display tick it lays the view graph out, takes the
// display list and calls `Compositor.render(_:)`. When the window's pixel
// size or scale changes it calls `surfaceDidResize()` before the next
// frame; before destroying the window it calls `invalidate()`.
//
// Vulkan handles cross the boundary as raw values so that neither side
// needs the other's C headers: a `VkInstance` is an `OpaquePointer`, a
// `VkSurfaceKHR` a `UInt64` (a non-dispatchable handle). Both sides load the
// system Vulkan loader (`libvulkan.so.1`; `YCODE_VULKAN_LIBRARY` overrides it
// on the render side, and the host should pass the same path to
// `SDL_Vulkan_LoadLibrary`).
//
// Threading: a compositor and its surface are used from one thread (the
// host's main thread); neither is Sendable.

import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Something a compositor draws into: a window, or an offscreen target.
public protocol RenderSurface: AnyObject {
    /// The drawable size in device pixels (the swapchain or framebuffer
    /// size). Read at every frame.
    var pixelSize: PixelSize { get }
    /// Device pixels per point (SwiftUI's display scale).
    var contentScale: Double { get }
    /// How frames reach the screen.
    var presentation: SurfacePresentation { get }
}

/// How a compositor presents frames on a surface.
public enum SurfacePresentation {
    /// A window the compositor can create a Vulkan swapchain for.
    case vulkan(any VulkanSurfaceProvider)
    /// A window that takes finished frames as CPU pixels (for hosts without
    /// a usable Vulkan driver; for SDL3 a streaming texture or a window
    /// surface).
    case software(any SoftwareSurfaceProvider)
    /// No window: frames stay in memory and are read with
    /// `Compositor.readback()` (tests, `ycode preview --render`).
    case offscreen
}

/// The window-system side of a Vulkan surface (SDL3: `SDL_Vulkan_*`).
public protocol VulkanSurfaceProvider: AnyObject {
    /// Instance extensions the window system needs, e.g. `VK_KHR_surface`
    /// and `VK_KHR_wayland_surface` (`SDL_Vulkan_GetInstanceExtensions`).
    var requiredInstanceExtensions: [String] { get }
    /// Creates a `VkSurfaceKHR` for the window on `instance` (a `VkInstance`)
    /// and returns the handle (`SDL_Vulkan_CreateSurface`). The compositor
    /// owns the surface afterwards and destroys it (`vkDestroySurfaceKHR`)
    /// before its instance, in `invalidate()`.
    func createVulkanSurface(instance: OpaquePointer) throws -> UInt64
}

/// The window-system side of a CPU-presented surface.
public protocol SoftwareSurfaceProvider: AnyObject {
    /// Shows `frame` (premultiplied RGBA8, top row first, `pixelSize` of the
    /// surface). `damage` lists the pixel rectangles that changed since the
    /// previous `present`; the host may copy only those.
    func present(_ frame: PixelImage, damage: [PixelRect])
}

/// One frame to render.
public struct RenderFrame: Sendable {
    public var displayList: DisplayList
    /// Device pixels per point; the display list is in points.
    public var scale: Double
    /// The colour the surface is cleared to before the list is drawn.
    public var background: RenderColor

    public init(displayList: DisplayList, scale: Double, background: RenderColor = .clear) {
        self.displayList = displayList
        self.scale = scale
        self.background = background
    }
}

/// What a compositor did for one frame.
public struct FrameReport: Sendable {
    /// Pixel rectangles redrawn (empty when nothing changed).
    public var damage: [PixelRect]
    /// Layers composited (1 + the groups kept in their own layers).
    public var layerCount: Int
    /// Seconds spent rasterising on the CPU.
    public var rasterSeconds: Double
    /// Seconds from the start of `render` until the frame was submitted.
    public var totalSeconds: Double

    public init(damage: [PixelRect], layerCount: Int, rasterSeconds: Double, totalSeconds: Double) {
        self.damage = damage
        self.layerCount = layerCount
        self.rasterSeconds = rasterSeconds
        self.totalSeconds = totalSeconds
    }
}

/// Turns display lists into pixels on a surface.
public protocol Compositor: AnyObject {
    /// "vulkan: <device name>" or "software".
    var backendDescription: String { get }
    /// Renders and presents one frame. Blocks while the swapchain has no
    /// free image (FIFO presentation paces the host at the display rate).
    @discardableResult
    func render(_ frame: RenderFrame) throws -> FrameReport
    /// The surface's `pixelSize` or `contentScale` changed; the next frame
    /// recreates size-dependent resources.
    func surfaceDidResize()
    /// The last rendered frame as pixels (premultiplied RGBA8). Every back
    /// end supports it; on a window it reads the frame back from the GPU.
    func readback() throws -> PixelImage
    /// Releases every resource tied to the surface. Call before the window
    /// is destroyed; the compositor cannot render afterwards.
    func invalidate()
}

/// Which back end `makeCompositor` picks.
public enum CompositorPreference: Sendable {
    /// Vulkan when the surface offers it and a device works, else software.
    case automatic
    /// Vulkan or an error.
    case vulkan
    /// The CPU path (ThorVG) presenting through the surface's software or
    /// offscreen presentation; for a Vulkan surface, through a swapchain
    /// fed by copies.
    case software
}

public enum CompositorError: Error, CustomStringConvertible {
    case unavailable(String)
    case vulkan(String)
    case surface(String)

    public var description: String {
        switch self {
        case .unavailable(let s): return "compositor unavailable: \(s)"
        case .vulkan(let s): return "vulkan: \(s)"
        case .surface(let s): return "surface: \(s)"
        }
    }
}
