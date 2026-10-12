// End-to-end check of the shader path: the probe's own metallib
// (SimShim/guest-tests/stage8, built by build-stage8.sh) translated by
// ycode-airc and drawn through VulkanMetalBackend, compared with the
// reference values of the same probe under CoreSimulator on a Mac.
// Needs YCODE_AIRC (the translator) and YCODE_TEST_PROBE_METALLIB.

import Foundation
import Testing
@testable import YcodeMetalHost
@testable import YcodeVulkan

/// Translates "probe:NAME" by asking ycode-airc for function NAME of the probe library.
final class ProbeLibraryTranslator: ShaderTranslator, @unchecked Sendable {
    let airc: AircProcessTranslator
    let library: [UInt8]
    init(airc: AircProcessTranslator, library: [UInt8]) { self.airc = airc; self.library = library }
    func translate(_ request: TranslationRequest) throws -> TranslatedShader {
        let name = String(decoding: request.metallib, as: UTF8.self)
        guard name.hasPrefix("probe:") else { throw ShaderTranslationError("not a probe function") }
        return try airc.translate(TranslationRequest(metallib: library, linkVertexHash: request.linkVertexHash,
                                                     functionName: String(name.dropFirst(6))))
    }
}

enum AircTest {
    static let env = ProcessInfo.processInfo.environment
    static let configured: Bool = {
        guard let a = env["YCODE_AIRC"], let m = env["YCODE_TEST_PROBE_METALLIB"] else { return false }
        return FileManager.default.isExecutableFile(atPath: a) && FileManager.default.fileExists(atPath: m)
    }()
}

@Suite(.serialized, .enabled(if: AircTest.configured && VK.available, "needs YCODE_AIRC, YCODE_TEST_PROBE_METALLIB and a GPU"))
struct AircIntegrationTests {
    @Test func probeTriangleThroughTranslator() throws {
        let lib = [UInt8](try Data(contentsOf: URL(fileURLWithPath: AircTest.env["YCODE_TEST_PROBE_METALLIB"]!)))
        let airc = AircProcessTranslator(executable: URL(fileURLWithPath: AircTest.env["YCODE_AIRC"]!))
        let b = VulkanMetalBackend(translator: ProbeLibraryTranslator(airc: airc, library: lib))
        defer { b.shutdown() }
        let vf = MetalHandle(1), ff = MetalHandle(2), pipe = MetalHandle(3), vb = MetalHandle(4), tex = MetalHandle(5)
        try b.createFunction(vf, metallib: Array("probe:triangle_vertex".utf8))
        try b.createFunction(ff, metallib: Array("probe:triangle_fragment".utf8))
        var desc = MetalRenderPipelineDescriptor()
        desc.vertexFunction = vf
        desc.fragmentFunction = ff
        var c = MetalColorAttachmentDescriptor(index: 0)
        c.pixelFormat = MetalPixelFormat.bgra8Unorm
        desc.colorAttachments = [c]
        var vd = MetalVertexDescriptor()
        var a0 = MetalVertexDescriptor.Attribute(index: 0); a0.format = 29; a0.offset = 0
        var a1 = MetalVertexDescriptor.Attribute(index: 1); a1.format = 31; a1.offset = 16
        var l0 = MetalVertexDescriptor.Layout(bufferIndex: 0); l0.stride = 32
        vd.attributes = [a0, a1]
        vd.layouts = [l0, l0]
        desc.vertexDescriptor = vd
        try b.createRenderPipeline(pipe, desc)

        let mem = HostPages(16384)
        let verts: [Float] = [0, 0.8, 0, 0, 1, 0, 0, 1,
                              -0.8, -0.8, 0, 0, 0, 1, 0, 1,
                              0.8, -0.8, 0, 0, 0, 0, 1, 1]
        for (i, v) in verts.enumerated() { mem.pointer.storeBytes(of: v, toByteOffset: 4 * i, as: Float.self) }
        try b.createBuffer(vb, length: 96, storage: .shared, guestMemory: mem.region(0, 96))
        try b.createTexture(tex, MetalTextureDescriptor(pixelFormat: MetalPixelFormat.bgra8Unorm, width: 512, height: 512,
                                                        usage: 0x5), iosurface: nil)
        var d = MetalRenderPassDescriptor()
        d.colorAttachments = [MetalColorAttachment(index: 0, attachment: MetalRenderPassAttachment(
            texture: tex, loadAction: MetalLoadAction.clear, storeAction: MetalStoreAction.store), clearColor: [0.10, 0.10, 0.15, 1])]
        let done = DispatchSemaphore(value: 0)
        let cb = MetalCommandBuffer(process: 1, queue: nil, commandBufferRef: 1, passes: [.render(MetalRenderPass(descriptor: d, commands: [
            .setRenderPipelineState(pipe),
            .setBuffer(stage: .vertex, index: 0, buffer: vb, offset: 0),
            .draw(MetalDraw(primitiveType: MetalPrimitiveType.triangle, vertexStart: 0, vertexCount: 3)),
        ]))])
        b.submit(cb, scheduled: {}, completed: { s in #expect(s == 4); done.signal() })
        #expect(done.wait(timeout: .now() + 10) == .success)
        let out = HostPages(512 * 512 * 4)
        try b.getBytes(texture: tex, MetalRegion(width: 512, height: 512), level: 0, slice: 0, into: out.region(0, 512 * 512 * 4),
                       bytesPerRow: 2048, bytesPerImage: 512 * 512 * 4)
        func rgb(_ x: Int, _ y: Int) -> [Int] {
            let p = out.bytes(4 * (y * 512 + x), 4)
            return [Int(p[2]), Int(p[1]), Int(p[0])]
        }
        // Reference: the probe under CoreSimulator (iOS 27.0, Apple iOS simulator GPU).
        let reference: [(Int, Int, [Int])] = [(8, 8, [26, 26, 38]), (256, 80, [237, 9, 9]), (70, 440, [13, 237, 6]),
                                              (440, 440, [13, 6, 236]), (256, 300, [100, 77, 78])]
        for (x, y, want) in reference {
            let got = rgb(x, y)
            print("probe pixel (\(x),\(y)) = \(got), reference \(want)")
            #expect(zip(got, want).allSatisfy { abs($0 - $1) <= 3 }, "pixel (\(x),\(y)) = \(got), reference \(want)")
        }
    }
}
