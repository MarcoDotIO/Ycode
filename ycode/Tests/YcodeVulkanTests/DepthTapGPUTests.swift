// The depth tap (specs/simulator/xr-depth.md §3.1): a windows layer's transparent
// parts write depth too, and the picture shows what lies behind them, so only the
// layer's opaque texels count; and a sample says whose it is (its low bit).

import Foundation
import Testing
@testable import YcodeVulkan
@testable import YcodeMetalHost

@Suite(.serialized, .enabled(if: VK.available, "needs a Vulkan GPU with VK_EXT_external_memory_host"))
struct DepthTapGPUTests {
    @Test func windowsDepthCountsOnlyWhereTheLayerIsOpaque() throws {
        let b = VK.backend
        let w = 1024, h = 576
        // The room: depth 0.25 everywhere (reverse-Z: a clear below 0.5 is not standard Z).
        let roomColour = try VK.texture(MetalPixelFormat.bgra8UnormSRGB, w, h)
        let roomDepth = try VK.texture(MetalPixelFormat.depth32Float, w, h, usage: 0x5)
        var room = MetalRenderPassDescriptor()
        room.colorAttachments = [MetalColorAttachment(index: 0, attachment: MetalRenderPassAttachment(
            texture: roomColour, loadAction: MetalLoadAction.clear, storeAction: MetalStoreAction.store))]
        room.depth = MetalRenderPassAttachment(texture: roomDepth, loadAction: MetalLoadAction.clear, storeAction: MetalStoreAction.store)
        room.clearDepth = 0.25
        room.renderTargetWidth = w
        room.renderTargetHeight = h

        // The windows: 4×, resolved; depth 0.5 everywhere (as a label's clear rectangle would write it),
        // transparent except where a triangle draws: (-1,-1), (1,-1), (0,1), its apex at the top.
        let msaa = VK.handle(), msaaDepth = VK.handle(), layer = try VK.texture(MetalPixelFormat.bgra8UnormSRGB, w, h)
        try b.createTexture(msaa, MetalTextureDescriptor(textureType: MetalTextureType.type2DMultisample, pixelFormat: MetalPixelFormat.bgra8UnormSRGB,
                                                         width: w, height: h, sampleCount: 4, usage: 0x4, resourceOptions: 0x20), iosurface: nil)
        try b.createTexture(msaaDepth, MetalTextureDescriptor(textureType: MetalTextureType.type2DMultisample, pixelFormat: MetalPixelFormat.depth32Float,
                                                              width: w, height: h, sampleCount: 4, usage: 0x5, resourceOptions: 0x20), iosurface: nil)
        let verts = HostPages(16384)
        let positions: [(Float, Float)] = [(-1, -1), (1, -1), (0, 1)]
        for (i, p) in positions.enumerated() {
            verts.pointer.storeBytes(of: p.0, toByteOffset: 12 * i, as: Float.self)
            verts.pointer.storeBytes(of: p.1, toByteOffset: 12 * i + 4, as: Float.self)
            verts.pointer.storeBytes(of: UInt32(0xFF00_00FF), toByteOffset: 12 * i + 8, as: UInt32.self)
        }
        for (i, v) in ([1, 1, 0, 0] as [Float]).enumerated() { verts.pointer.storeBytes(of: v, toByteOffset: 4096 + 4 * i, as: Float.self) }
        let vb = VK.handle(), xb = VK.handle(), pipe = VK.handle()
        try b.createBuffer(vb, length: 36, storage: .shared, guestMemory: verts.region(0, 36))
        try b.createBuffer(xb, length: 16, storage: .shared, guestMemory: verts.region(4096, 16))
        var desc = MetalRenderPipelineDescriptor()
        desc.vertexFunction = try VK.function("tri.vert")
        desc.fragmentFunction = try VK.function("color.frag")
        var c = MetalColorAttachmentDescriptor(index: 0)
        c.pixelFormat = MetalPixelFormat.bgra8UnormSRGB
        desc.colorAttachments = [c]
        desc.depthAttachmentPixelFormat = MetalPixelFormat.depth32Float
        desc.rasterSampleCount = 4
        var vd = MetalVertexDescriptor()
        var a0 = MetalVertexDescriptor.Attribute(index: 0); a0.format = 29; a0.offset = 0; a0.bufferIndex = 0
        var a1 = MetalVertexDescriptor.Attribute(index: 1); a1.format = 9; a1.offset = 8; a1.bufferIndex = 0
        var l0 = MetalVertexDescriptor.Layout(bufferIndex: 0); l0.stride = 12
        vd.attributes = [a0, a1]
        vd.layouts = [l0, l0]
        desc.vertexDescriptor = vd
        try b.createRenderPipeline(pipe, desc)
        var windows = MetalRenderPassDescriptor()
        windows.colorAttachments = [MetalColorAttachment(index: 0, attachment: MetalRenderPassAttachment(
            texture: msaa, resolveTexture: layer, loadAction: MetalLoadAction.clear, storeAction: MetalStoreAction.multisampleResolve), clearColor: [0, 0, 0, 0])]
        windows.depth = MetalRenderPassAttachment(texture: msaaDepth, loadAction: MetalLoadAction.clear, storeAction: MetalStoreAction.dontCare)
        windows.clearDepth = 0.5
        windows.renderTargetWidth = w
        windows.renderTargetHeight = h
        let draw: [MetalRenderCommand] = [
            .setRenderPipelineState(pipe),
            .setBuffer(stage: .vertex, index: 0, buffer: vb, offset: 0),
            .setBuffer(stage: .vertex, index: 1, buffer: xb, offset: 0),
            .draw(MetalDraw(primitiveType: MetalPrimitiveType.triangle, vertexStart: 0, vertexCount: 3, baseInstance: 0)),
        ]

        XRDepthTap.shared.request(downscale: 4)
        defer { XRDepthTap.shared.request(downscale: 0) }
        let status = VK.run([.render(MetalRenderPass(descriptor: room, commands: [.setCullMode(0)])),
                             .render(MetalRenderPass(descriptor: windows, commands: draw))]).status
        #expect(status == 4)
        // A later command buffer collects the finished capture.
        var capture: XRDepthCapture?
        for _ in 0..<20 where capture == nil {
            VK.run([VK.colorPass(roomColour)])
            capture = XRDepthTap.shared.depth(forSurface: 0).flatMap { $0.capture.windowsPasses > 0 ? $0.capture : nil }
        }
        let got = try #require(capture)
        #expect(got.width == 256 && got.height == 144)
        func at(_ x: Int, _ y: Int) -> UInt16 { got.samples[y * got.width + x] }
        // Where the layer is opaque: the windows' depth, marked.
        let inside = at(128, 130)
        #expect(abs(Int(inside) - 32768) < 4, "inside \(inside)")
        #expect(inside & 1 == 1, "inside \(inside) is not marked")
        // Where it is transparent: the room's depth, unmarked, though the windows' depth is nearer there.
        let outside = at(5, 5)
        #expect(abs(Int(outside) - 16384) < 4, "outside \(outside)")
        #expect(outside & 1 == 0, "outside \(outside) is marked")
        withExtendedLifetime(verts) {}
        for t in [msaa, msaaDepth, layer, roomColour, roomDepth] { b.release(t) }
    }
}
