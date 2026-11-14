// The compositors (09-open-design.md §3.5–§3.6).
//
// SoftwareCompositor: the whole frame is rasterised on the CPU into one
// persistent image; only the damage between the previous and the new
// display list is redrawn, and only that is handed to the host.
//
// VulkanCompositor: a GPU layer tree. The top-level items of a display list
// are cut into layers: every top-level group marked `isLayer` (and normally
// blended) becomes its own layer, rasterised once in its local coordinates
// and composited with its transform and opacity, so moving or fading it
// costs no rasterisation; the runs of items between such groups become
// full-surface layers ("slabs") that are redrawn only where they changed.
// Layers are RGBA8 textures; a frame clears the target and draws the layers
// in order as textured quads (premultiplied alpha).

import COVVulkan
import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// A compositor for `surface`. With `.automatic`, a Vulkan surface gets the
/// Vulkan compositor when a device works and the software compositor
/// otherwise; software and offscreen surfaces get the software compositor
/// (which rasterises with ThorVG on the CPU). `.vulkan` on an offscreen
/// surface renders through an offscreen Vulkan target (tests).
public func makeCompositor(for surface: any RenderSurface,
                           preference: CompositorPreference = .automatic) throws -> any Compositor {
    switch (surface.presentation, preference) {
    case (.vulkan, .automatic):
        if let c = try? VulkanCompositor(surface: surface, layers: true) { return c }
        return SoftwareCompositor(surface: surface)
    case (.vulkan, .vulkan):
        return try VulkanCompositor(surface: surface, layers: true)
    case (.vulkan, .software):
        return try VulkanCompositor(surface: surface, layers: false)
    case (.offscreen, .vulkan):
        return try VulkanCompositor(surface: surface, layers: true)
    case (.software, .vulkan):
        throw CompositorError.surface("a software surface cannot present Vulkan frames")
    case (.software, _), (.offscreen, _):
        return SoftwareCompositor(surface: surface)
    }
}

/// An offscreen surface of a fixed size (tests, headless rendering).
public final class OffscreenSurface: RenderSurface {
    public var pixelSize: PixelSize
    public var contentScale: Double
    public var presentation: SurfacePresentation { .offscreen }
    public init(pixelSize: PixelSize, contentScale: Double) {
        self.pixelSize = pixelSize
        self.contentScale = contentScale
    }
}

private func cString(_ chars: [CChar]) -> String {
    String(decoding: chars.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
}

private func seconds(since start: DispatchTime) -> Double {
    Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e9
}

// MARK: - Software

public final class SoftwareCompositor: Compositor {
    private let surface: any RenderSurface
    private let rasterizer = SoftwareRasterizer()
    private var image: PixelImage
    private var last: DisplayList?
    private var lastScale = 0.0
    private var lastBackground = RenderColor.clear

    public init(surface: any RenderSurface) {
        self.surface = surface
        image = PixelImage(size: surface.pixelSize)
    }

    public var backendDescription: String { "software (ThorVG CPU)" }

    @discardableResult
    public func render(_ frame: RenderFrame) throws -> FrameReport {
        let start = DispatchTime.now()
        let size = surface.pixelSize
        var damage: [PixelRect]
        if image.size != size || last == nil || lastScale != frame.scale || lastBackground != frame.background {
            image = PixelImage(size: size)
            damage = [PixelRect(x: 0, y: 0, width: size.width, height: size.height)]
        } else if let last {
            damage = DisplayListDiff.pixelDamage(from: last, to: frame.displayList, scale: frame.scale, size: size)
        } else {
            damage = []
        }
        for d in damage {
            rasterizer.render(frame.displayList, into: &image, scale: frame.scale, background: frame.background, region: d)
        }
        let raster = seconds(since: start)
        last = frame.displayList
        lastScale = frame.scale
        lastBackground = frame.background
        if case .software(let provider) = surface.presentation, !damage.isEmpty { provider.present(image, damage: damage) }
        return FrameReport(damage: damage, layerCount: 1, rasterSeconds: raster, totalSeconds: seconds(since: start))
    }

    public func surfaceDidResize() { last = nil }
    public func readback() throws -> PixelImage { image }
    public func invalidate() { last = nil }
}

// MARK: - Vulkan

public final class VulkanCompositor: Compositor {
    private let surface: any RenderSurface
    private var ctx: OpaquePointer?
    private let hoistLayers: Bool
    private let rasterizer = SoftwareRasterizer()
    private var targetSize = PixelSize(width: 0, height: 0)
    private var lastDraws: [ovk_draw] = []
    private var lastClear: [Float] = [0, 0, 0, 0]

    private struct Slab {
        var list: DisplayList
        var image: PixelImage
        var scale: Double
    }
    private struct Hoisted {
        var content: DisplayGroup
        var origin: PixelRect
        var scale: Double
    }
    private enum LayerState {
        case slab(Slab)
        case hoisted(Hoisted)
    }
    /// Layer contents by texture index.
    private var layers: [UInt32: LayerState] = [:]
    /// Texture index of each hoisted group by item ID; slabs by position.
    private var hoistedIndex: [DisplayItemID: UInt32] = [:]
    private var slabIndex: [UInt32] = []
    private var nextIndex: UInt32 = 0

    public let deviceName: String
    public let deviceIsCPU: Bool

    init(surface: any RenderSurface, layers hoist: Bool) throws {
        self.surface = surface
        hoistLayers = hoist
        var err = [CChar](repeating: 0, count: 512)
        let size = surface.pixelSize
        let made: OpaquePointer
        switch surface.presentation {
        case .vulkan(let provider):
            let exts = provider.requiredInstanceExtensions
            let cstrs = exts.map { strdup($0) }
            defer { cstrs.forEach { free($0) } }
            let ptrs: [UnsafePointer<CChar>?] = cstrs.map { UnsafePointer($0) }
            guard let c = ptrs.withUnsafeBufferPointer({ ovk_create($0.baseAddress, UInt32(exts.count), 1, &err, err.count) }) else {
                throw CompositorError.vulkan(cString(err))
            }
            guard let instance = ovk_instance(c) else {
                ovk_destroy(c)
                throw CompositorError.vulkan("no instance")
            }
            let handle: UInt64
            do {
                handle = try provider.createVulkanSurface(instance: OpaquePointer(instance))
            } catch {
                ovk_destroy(c)
                throw error
            }
            guard ovk_attach_surface(c, handle, UInt32(max(1, size.width)), UInt32(max(1, size.height)), &err, err.count) == 0 else {
                ovk_destroy(c)
                throw CompositorError.vulkan(cString(err))
            }
            made = c
        case .offscreen:
            guard let c = ovk_create(nil, 0, 0, &err, err.count) else { throw CompositorError.vulkan(cString(err)) }
            guard ovk_set_offscreen(c, UInt32(max(1, size.width)), UInt32(max(1, size.height)), &err, err.count) == 0 else {
                ovk_destroy(c)
                throw CompositorError.vulkan(cString(err))
            }
            made = c
        case .software:
            throw CompositorError.surface("a software surface cannot present Vulkan frames")
        }
        ctx = made
        deviceName = String(cString: ovk_device_name(made))
        deviceIsCPU = ovk_device_is_cpu(made) != 0
        var w: UInt32 = 0, h: UInt32 = 0
        ovk_target_size(made, &w, &h)
        targetSize = PixelSize(width: Int(w), height: Int(h))
    }

    deinit { invalidate() }

    public var backendDescription: String { "vulkan: \(deviceName)" + (deviceIsCPU ? " (CPU)" : "") }

    /// The context's VkInstance (nil once invalidated): contexts with the
    /// same extensions share one (ov_vulkan.c, "Shared instances").
    package var instanceHandle: UInt? { ctx.flatMap { ovk_instance($0) }.map { UInt(bitPattern: $0) } }

    public func surfaceDidResize() {
        guard let ctx else { return }
        var err = [CChar](repeating: 0, count: 512)
        let size = surface.pixelSize
        _ = ovk_resize(ctx, UInt32(max(1, size.width)), UInt32(max(1, size.height)), &err, err.count)
        var w: UInt32 = 0, h: UInt32 = 0
        ovk_target_size(ctx, &w, &h)
        targetSize = PixelSize(width: Int(w), height: Int(h))
    }

    public func invalidate() {
        if let ctx { ovk_destroy(ctx) }
        ctx = nil
        layers = [:]
        hoistedIndex = [:]
        slabIndex = []
    }

    private func newIndex() -> UInt32 {
        defer { nextIndex += 1 }
        return nextIndex
    }

    private enum Segment {
        case slab([DisplayItem])
        case hoisted(DisplayItem, DisplayGroup)
    }

    @discardableResult
    public func render(_ frame: RenderFrame) throws -> FrameReport {
        guard let ctx else { throw CompositorError.unavailable("the compositor was invalidated") }
        let start = DispatchTime.now()
        if surface.pixelSize != targetSize { surfaceDidResize() }
        let size = targetSize
        let scale = frame.scale
        var err = [CChar](repeating: 0, count: 512)

        // Cut the list into slabs and hoisted layer groups.
        var segments: [Segment] = []
        var run: [DisplayItem] = []
        for item in frame.displayList.items {
            if hoistLayers, case .group(let g) = item.content, g.isLayer, g.blendMode == .normal {
                if !run.isEmpty { segments.append(.slab(run)) }
                run = []
                segments.append(.hoisted(item, g))
            } else {
                run.append(item)
            }
        }
        if !run.isEmpty || segments.isEmpty { segments.append(.slab(run)) }

        var draws: [ovk_draw] = []
        var damage: [PixelRect] = []
        var rasterTime = 0.0
        var usedSlabs = 0
        var usedHoisted = Set<DisplayItemID>()
        let full = PixelRect(x: 0, y: 0, width: size.width, height: size.height)
        func fullScissor(_ index: UInt32, _ t: RenderTransform, opacity: Double) -> ovk_draw {
            ovk_draw(layer: index, a: Float(t.a), b: Float(t.b), c: Float(t.c), d: Float(t.d), tx: Float(t.tx), ty: Float(t.ty),
                     opacity: Float(opacity), scissor_x: 0, scissor_y: 0, scissor_w: Int32(size.width), scissor_h: Int32(size.height))
        }
        for seg in segments {
            switch seg {
            case .slab(let items):
                if usedSlabs == slabIndex.count { slabIndex.append(newIndex()) }
                let index = slabIndex[usedSlabs]
                usedSlabs += 1
                let list = DisplayList(items)
                var slab: Slab
                var regions: [PixelRect]
                if case .slab(let s)? = layers[index], s.image.size == size, s.scale == scale {
                    slab = s
                    regions = DisplayListDiff.pixelDamage(from: s.list, to: list, scale: scale, size: size)
                } else {
                    slab = Slab(list: list, image: PixelImage(size: size), scale: scale)
                    regions = [full]
                    guard ovk_layer_ensure(ctx, index, UInt32(size.width), UInt32(size.height), &err, err.count) == 0 else {
                        throw CompositorError.vulkan(cString(err))
                    }
                }
                let t0 = DispatchTime.now()
                for r in regions { rasterizer.render(list, into: &slab.image, scale: scale, background: .clear, region: r) }
                rasterTime += seconds(since: t0)
                slab.image.rgba.withUnsafeBytes { raw in
                    for r in regions where !r.isEmpty {
                        _ = ovk_layer_update(ctx, index, raw.baseAddress, UInt32(r.x), UInt32(r.y), UInt32(r.width), UInt32(r.height))
                    }
                }
                damage += regions
                slab.list = list
                layers[index] = .slab(slab)
                draws.append(fullScissor(index, .identity, opacity: 1))
            case let .hoisted(item, g):
                usedHoisted.insert(item.id)
                var content = g
                content.transform = .identity
                content.opacity = 1
                content.isLayer = false
                let local = DisplayListDiff.bounds(DisplayItem(id: item.id, .group(content)), .identity)
                guard !local.isNull, !local.isEmpty else { continue }
                let origin = PixelRect.covering(local, scale: scale)
                let index = hoistedIndex[item.id] ?? newIndex()
                hoistedIndex[item.id] = index
                var changed = true
                if case .hoisted(let h)? = layers[index], h.content == content, h.origin == origin, h.scale == scale { changed = false }
                if changed {
                    guard ovk_layer_ensure(ctx, index, UInt32(origin.width), UInt32(origin.height), &err, err.count) == 0 else {
                        throw CompositorError.vulkan(cString(err))
                    }
                    let t0 = DispatchTime.now()
                    let shifted = DisplayItem(id: item.id, .group(content)).translated(-Double(origin.x) / scale, -Double(origin.y) / scale)
                    var img = PixelImage(size: PixelSize(width: origin.width, height: origin.height))
                    rasterizer.render(DisplayList([shifted]), into: &img, scale: scale, background: .clear, region: nil)
                    rasterTime += seconds(since: t0)
                    img.rgba.withUnsafeBytes { raw in
                        _ = ovk_layer_update(ctx, index, raw.baseAddress, 0, 0, UInt32(origin.width), UInt32(origin.height))
                    }
                    layers[index] = .hoisted(Hoisted(content: content, origin: origin, scale: scale))
                }
                // Layer pixels → target pixels: scale ∘ transform ∘ origin offset ∘ 1/scale.
                let t = RenderTransform.scale(scale, scale).concatenating(g.transform)
                    .concatenating(.translation(Double(origin.x) / scale, Double(origin.y) / scale))
                    .concatenating(.scale(1 / scale, 1 / scale))
                draws.append(fullScissor(index, t, opacity: g.opacity))
                damage.append(PixelRect.covering(RenderTransform.scale(scale, scale).concatenating(g.transform).boundingBox(of: local), scale: 1)
                    .intersection(full))
            }
        }
        // Release layers that are no longer used.
        for (id, index) in hoistedIndex where !usedHoisted.contains(id) {
            ovk_layer_release(ctx, index)
            layers[index] = nil
            hoistedIndex[id] = nil
        }
        while slabIndex.count > usedSlabs, let index = slabIndex.popLast() {
            ovk_layer_release(ctx, index)
            layers[index] = nil
        }
        let bg = frame.background
        let clear: [Float] = [Float(bg.red * bg.alpha), Float(bg.green * bg.alpha), Float(bg.blue * bg.alpha), Float(bg.alpha)]
        var wantRead: Int32 = 0
        if case .offscreen = surface.presentation { wantRead = 1 }
        var status = draws.withUnsafeBufferPointer { ovk_frame(ctx, $0.baseAddress, UInt32($0.count), clear, wantRead, &err, err.count) }
        if status == 1 {
            surfaceDidResize()
            status = draws.withUnsafeBufferPointer { ovk_frame(ctx, $0.baseAddress, UInt32($0.count), clear, wantRead, &err, err.count) }
        }
        guard status >= 0 else { throw CompositorError.vulkan(cString(err)) }
        lastDraws = draws
        lastClear = clear
        return FrameReport(damage: damage.filter { !$0.isEmpty }, layerCount: draws.count, rasterSeconds: rasterTime,
                           totalSeconds: seconds(since: start))
    }

    public func readback() throws -> PixelImage {
        guard let ctx else { throw CompositorError.unavailable("the compositor was invalidated") }
        var err = [CChar](repeating: 0, count: 512)
        if case .vulkan = surface.presentation {
            // Draw the last frame again with a copy for reading.
            let status = lastDraws.withUnsafeBufferPointer { ovk_frame(ctx, $0.baseAddress, UInt32($0.count), lastClear, 1, &err, err.count) }
            guard status >= 0 else { throw CompositorError.vulkan(cString(err)) }
        }
        var img = PixelImage(size: targetSize)
        let ok = img.rgba.withUnsafeMutableBytes { ovk_readback(ctx, $0.baseAddress, $0.count) }
        guard ok == 0 else { throw CompositorError.vulkan("read-back is not available on this target") }
        return img
    }
}
