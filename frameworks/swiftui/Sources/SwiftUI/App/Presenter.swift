import Foundation
import OVPlatform
import OVRender
#if OPENVIEWS_RENAMED
import OpenViewsCore
#else
import SwiftUICore
#endif

// Frame presentation through round R5's compositors (`OVRender/Compositor.swift`;
// 09-open-design.md §3.6). Each window is a `RenderSurface`: a window created
// for Vulkan offers `.vulkan` (the compositor creates its instance and asks
// the window for the `VkSurfaceKHR`), any other window `.software` (finished
// CPU frames go to the window's surface). Once per display tick the host
// lowers the laid-out graph to a display list (`ViewGraph.displayList()`) and
// calls `Compositor.render`. If no compositor can be made for a software
// window, frames are rasterised with R5's `SoftwareRasterizer` and presented
// directly. The application host picks Vulkan windows when a Vulkan
// compositor works (AppHost.swift, `OV_RENDERER`).

/// Draws a window's current state.
@MainActor
package protocol FramePresenter: AnyObject {
    func present(_ window: WindowHost)
    /// The window's pixel size or scale changed.
    func surfaceDidResize()
    /// The window is about to be destroyed.
    func invalidate()
    /// The last presented frame, read back.
    func readback() -> PixelBuffer?
}

/// A platform window as R5's render surface. OVRender's protocols are not
/// actor-isolated; the host and its compositor use them on the main thread
/// only (09-open-design.md §3.6), hence the unchecked conformance.
final class WindowRenderSurface: RenderSurface, OVRender.VulkanSurfaceProvider, SoftwareSurfaceProvider,
    @unchecked Sendable {
    nonisolated(unsafe) let window: any PlatformWindow

    init(_ window: any PlatformWindow) { self.window = window }

    var pixelSize: PixelSize {
        MainActor.assumeIsolated {
            let p = window.pixelSize
            return PixelSize(width: p.width, height: p.height)
        }
    }

    var contentScale: Double { MainActor.assumeIsolated { window.scale } }

    var presentation: SurfacePresentation {
        let vulkan = MainActor.assumeIsolated { window.vulkan != nil }
        return vulkan ? .vulkan(self) : .software(self)
    }

    var requiredInstanceExtensions: [String] {
        MainActor.assumeIsolated { window.vulkan?.requiredInstanceExtensions() ?? [] }
    }

    func createVulkanSurface(instance: OpaquePointer) throws -> UInt64 {
        let raw = UInt(bitPattern: Int(bitPattern: UnsafeMutableRawPointer(instance)))
        return try MainActor.assumeIsolated {
            guard let v = window.vulkan, let p = UnsafeMutableRawPointer(bitPattern: raw) else {
                throw CompositorError.surface("window has no Vulkan surface")
            }
            return try v.createSurface(instance: p)
        }
    }

    func present(_ frame: PixelImage, damage: [PixelRect]) {
        let buffer = PixelBuffer(width: frame.size.width, height: frame.size.height, bytes: frame.rgba)
        MainActor.assumeIsolated { window.present(buffer) }
    }
}

/// Presents frames through R5's compositor, or R5's CPU rasteriser while no
/// compositor is available.
@MainActor
package final class CompositorPresenter: FramePresenter {
    let surface: WindowRenderSurface
    package private(set) var compositor: (any Compositor)?
    /// Why there is no compositor (the CPU path is used).
    package private(set) var compositorError: String?
    private let rasterizer = SoftwareRasterizer()
    package private(set) var lastFrame: PixelBuffer?

    init(window: any PlatformWindow, preference: CompositorPreference? = nil) {
        surface = WindowRenderSurface(window)
        do {
            // A Vulkan window takes the Vulkan compositor or nothing (a CPU
            // compositor cannot present to it); other windows the software one.
            let pref = preference ?? (window.vulkan != nil ? .vulkan : .automatic)
            compositor = try makeCompositor(for: surface, preference: pref)
        } catch {
            compositorError = "\(error)"
        }
    }

    /// "vulkan: …", "software" (R5's compositors) or "cpu-rasterizer".
    package var description: String { compositor?.backendDescription ?? "cpu-rasterizer" }

    private static func renderColor(_ c: Color.Resolved) -> RenderColor {
        RenderColor(red: Double(c.red), green: Double(c.green), blue: Double(c.blue), alpha: Double(c.opacity))
    }

    package func makeFrame(_ window: WindowHost) -> RenderFrame {
        let env = window.graph.environment
        let list = window.graph.displayList()
        let background: RenderColor = env.colorScheme == .dark ? .black : .white
        return RenderFrame(displayList: list, scale: window.platform.scale, background: background)
    }

    package func present(_ window: WindowHost) {
        let frame = makeFrame(window)
        if let compositor {
            do {
                try compositor.render(frame)
                return
            } catch {
                compositorError = "\(error)"
                self.compositor = nil
            }
        }
        // A Vulkan window has no CPU surface to fall back to.
        guard window.platform.vulkan == nil else { return }
        let image = rasterizer.render(frame, size: surface.pixelSize)
        let buffer = PixelBuffer(width: image.size.width, height: image.size.height, bytes: image.rgba)
        lastFrame = buffer
        window.platform.present(buffer)
    }

    package func surfaceDidResize() { compositor?.surfaceDidResize() }
    package func invalidate() { compositor?.invalidate() }

    package func readback() -> PixelBuffer? {
        if let compositor, let img = try? compositor.readback() {
            return PixelBuffer(width: img.size.width, height: img.size.height, bytes: img.rgba)
        }
        return lastFrame
    }
}
