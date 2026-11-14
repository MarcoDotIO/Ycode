import Foundation
import OVRender
import Testing
#if OPENVIEWS_RENAMED
@testable import OpenViewsCore
@testable import OpenViews
#else
@testable import SwiftUICore
@testable import SwiftUI
#endif

// The compositors (09 §3.5–§3.6): the software compositor's damage
// tracking, display-list identity and diffing, and the Vulkan compositor on
// an offscreen target compared with the CPU rasteriser. Hosts without a
// Vulkan loader (macOS) skip the Vulkan cases unless OV_REQUIRE_VULKAN=1;
// OV_VULKAN_DEVICE picks the device (e.g. "llvmpipe" for lavapipe).

@MainActor
private func displayList<V: View>(_ v: V, width: CGFloat, height: CGFloat) -> DisplayList {
    let g = HeadlessRenderer.makeGraph(v, mode: .window(CGSize(width: width, height: height), safeAreaInsets: EdgeInsets()),
                                       scale: 2, colorScheme: .light)
    g.update()
    return g.displayList()
}

private func maxDifference(_ a: PixelImage, _ b: PixelImage) -> (worst: Int, over: Int) {
    var worst = 0, over = 0
    for i in 0..<min(a.rgba.count, b.rgba.count) {
        let d = abs(Int(a.rgba[i]) - Int(b.rgba[i]))
        worst = max(worst, d)
        if d > 2 { over += 1 }
    }
    return (worst, over)
}

@Suite("Display list identity and damage (09 §3.5)")
@MainActor
struct DisplayListDiffTests {
    @Test("The same view gives the same list; a colour change damages only that view") func identityAndDamage() {
        struct Scene: View {
            var color: Color
            var body: some View {
                HStack(spacing: 10) {
                    Color.blue.frame(width: 20, height: 20)
                    color.frame(width: 20, height: 20)
                }
            }
        }
        let a = displayList(Scene(color: .red), width: 100, height: 40)
        let a2 = displayList(Scene(color: .red), width: 100, height: 40)
        #expect(DisplayListDiff.damage(from: a, to: a2).isEmpty || a.items.map(\.content) == a2.items.map(\.content))
        // Within one graph, an update keeps item IDs; only the changed item damages.
        let graph = HeadlessRenderer.makeGraph(Scene(color: .red), mode: .window(CGSize(width: 100, height: 40), safeAreaInsets: EdgeInsets()),
                                               scale: 2, colorScheme: .light)
        graph.update()
        let before = graph.displayList()
        graph.setRootView(Scene(color: .green))
        graph.update()
        let after = graph.displayList()
        #expect(before.items.map(\.id) == after.items.map(\.id))
        let damage = DisplayListDiff.damage(from: before, to: after)
        #expect(damage.count == 1)
        // The second square is at x = 55…75 (the stack, 50 wide, is centred in 100).
        if let d = damage.first {
            #expect(d.minX >= 54 && d.maxX <= 76, "\(d)")
        }
    }

    @Test("Damage of moved, added and removed items") func movedItems() {
        let r = RenderPath(rect: CGRect(x: 0, y: 0, width: 10, height: 10))
        let item = DisplayItem(id: DisplayItemID(1), .fill(r, .color(.black), .nonZero))
        let moved = item.translated(30, 0)
        let d = DisplayListDiff.damage(from: DisplayList([item]), to: DisplayList([moved]))
        #expect(d.count == 2)
        let added = DisplayListDiff.damage(from: DisplayList([]), to: DisplayList([item]))
        #expect(added == [CGRect(x: 0, y: 0, width: 10, height: 10)])
        let group = DisplayItem(id: DisplayItemID(2), .group(DisplayGroup(opacity: 0.5, children: [item])))
        let faded = DisplayItem(id: DisplayItemID(2), .group(DisplayGroup(opacity: 0.25, children: [item])))
        #expect(DisplayListDiff.damage(from: DisplayList([group]), to: DisplayList([faded])) == [CGRect(x: 0, y: 0, width: 10, height: 10)])
    }
}

@Suite("Software compositor")
@MainActor
struct SoftwareCompositorTests {
    @Test("Damage-only redraws give the same pixels as full renders") func damage() throws {
        let surface = OffscreenSurface(pixelSize: PixelSize(width: 480, height: 340), contentScale: 2)
        let comp = try makeCompositor(for: surface, preference: .software)
        #expect(comp.backendDescription.hasPrefix("software"))
        let first = displayList(SampleScenes.composite, width: 240, height: 170)
        let r1 = try comp.render(RenderFrame(displayList: first, scale: 2, background: .white))
        #expect(r1.damage == [PixelRect(x: 0, y: 0, width: 480, height: 340)])
        let again = try comp.render(RenderFrame(displayList: first, scale: 2, background: .white))
        #expect(again.damage.isEmpty)
        // A second, changed list: only part of the surface is redrawn.
        var changed = first
        changed.items.append(DisplayItem(id: DisplayItemID(42), .fill(RenderPath(rect: CGRect(x: 10, y: 10, width: 20, height: 20)),
                                                                       .color(.black), .nonZero)))
        let r2 = try comp.render(RenderFrame(displayList: changed, scale: 2, background: .white))
        let area = r2.damage.reduce(0) { $0 + $1.width * $1.height }
        #expect(area < 480 * 340 / 4)
        let full = SoftwareRasterizer().render(RenderFrame(displayList: changed, scale: 2, background: .white), size: surface.pixelSize)
        #expect(try comp.readback() == full)
    }
}

/// The Vulkan compositor, when this host has a device.
@MainActor
private func vulkanCompositor(_ surface: any RenderSurface) throws -> (any Compositor)? {
    do {
        return try makeCompositor(for: surface, preference: .vulkan)
    } catch {
        if ProcessInfo.processInfo.environment["OV_REQUIRE_VULKAN"] == "1" { throw error }
        return nil
    }
}

@Suite("Vulkan compositor (offscreen)")
@MainActor
struct VulkanCompositorTests {
    @Test("The golden scene through Vulkan matches the CPU rasteriser") func goldenScene() throws {
        let surface = OffscreenSurface(pixelSize: PixelSize(width: 480, height: 340), contentScale: 2)
        guard let comp = try vulkanCompositor(surface) else { return }
        print("vulkan device:", comp.backendDescription)
        let list = displayList(SampleScenes.composite, width: 240, height: 170)
        let frame = RenderFrame(displayList: list, scale: 2, background: .white)
        try comp.render(frame)
        let gpu = try comp.readback()
        R5.save(gpu, "vulkan.composite")
        let cpu = SoftwareRasterizer().render(frame, size: surface.pixelSize)
        let d = maxDifference(gpu, cpu)
        #expect(d.over == 0, "worst \(d.worst), \(d.over) channel values differ by more than 2")
        #expect(R5.compareGolden(gpu, "img.composite") == nil)
    }

    @Test("Layers: a drawing group moves and fades without being rasterised again") func layers() throws {
        let surface = OffscreenSurface(pixelSize: PixelSize(width: 200, height: 100), contentScale: 2)
        guard let comp = try vulkanCompositor(surface) else { return }
        func scene(_ x: Double, _ opacity: Double) -> DisplayList {
            let content = DisplayItem(id: DisplayItemID(7), .fill(RenderPath(rect: CGRect(x: 0, y: 0, width: 20, height: 20)),
                                                                  .color(RenderColor(red: 1, green: 0, blue: 0)), .nonZero))
            let layer = DisplayGroup(transform: .translation(x, 10), opacity: opacity, isLayer: true, children: [content])
            let below = DisplayItem(id: DisplayItemID(1), .fill(RenderPath(rect: CGRect(x: 0, y: 0, width: 100, height: 50)),
                                                                .color(RenderColor(red: 0.9, green: 0.9, blue: 1)), .nonZero))
            return DisplayList([below, DisplayItem(id: DisplayItemID(8), .group(layer))])
        }
        for (x, o) in [(10.0, 1.0), (40.0, 1.0), (60.0, 0.5)] {
            let frame = RenderFrame(displayList: scene(x, o), scale: 2, background: .white)
            let report = try comp.render(frame)
            #expect(report.layerCount == 2)
            let gpu = try comp.readback()
            let cpu = SoftwareRasterizer().render(frame, size: surface.pixelSize)
            let d = maxDifference(gpu, cpu)
            #expect(d.over <= 8, "x \(x): worst \(d.worst), \(d.over) channel values differ by more than 2")
        }
    }

    @Test("Contexts share one instance; closing one leaves the others drawing") func sharedInstance() throws {
        // Each window has a context. Destroying a closed window's instance
        // broke the other windows' swapchains on NVIDIA's Wayland driver
        // (the Linux IDE crashed after the runtime wizard closed), so the
        // instance outlives every context but the last.
        let list = DisplayList([DisplayItem(id: DisplayItemID(1), .fill(RenderPath(rect: CGRect(x: 0, y: 0, width: 16, height: 16)),
                                                                         .color(.black), .nonZero))])
        let frame = RenderFrame(displayList: list, scale: 1, background: .white)
        let s1 = OffscreenSurface(pixelSize: PixelSize(width: 32, height: 32), contentScale: 1)
        let s2 = OffscreenSurface(pixelSize: PixelSize(width: 32, height: 32), contentScale: 1)
        guard let a = try vulkanCompositor(s1) as? VulkanCompositor, let b = try vulkanCompositor(s2) as? VulkanCompositor else { return }
        #expect(a.instanceHandle != nil && a.instanceHandle == b.instanceHandle)
        try a.render(frame)
        a.invalidate()
        #expect(a.instanceHandle == nil)
        try b.render(frame)
        #expect(try b.readback().pixel(x: 4, y: 4) == (0, 0, 0, 255))
        let s3 = OffscreenSurface(pixelSize: PixelSize(width: 32, height: 32), contentScale: 1)
        let c = try #require(try vulkanCompositor(s3) as? VulkanCompositor)
        #expect(c.instanceHandle == b.instanceHandle)
        try c.render(frame)
        #expect(try c.readback().pixel(x: 20, y: 20) == (255, 255, 255, 255))
        b.invalidate()
        c.invalidate()
    }

    @Test("Resizing the offscreen target") func resize() throws {
        let surface = OffscreenSurface(pixelSize: PixelSize(width: 64, height: 64), contentScale: 1)
        guard let comp = try vulkanCompositor(surface) else { return }
        let list = DisplayList([DisplayItem(id: DisplayItemID(1), .fill(RenderPath(rect: CGRect(x: 0, y: 0, width: 32, height: 32)),
                                                                         .color(.black), .nonZero))])
        try comp.render(RenderFrame(displayList: list, scale: 1, background: .white))
        surface.pixelSize = PixelSize(width: 100, height: 50)
        try comp.render(RenderFrame(displayList: list, scale: 1, background: .white))
        let img = try comp.readback()
        #expect(img.size == PixelSize(width: 100, height: 50))
        #expect(img.pixel(x: 10, y: 10) == (0, 0, 0, 255))
        #expect(img.pixel(x: 60, y: 10) == (255, 255, 255, 255))
    }
}
