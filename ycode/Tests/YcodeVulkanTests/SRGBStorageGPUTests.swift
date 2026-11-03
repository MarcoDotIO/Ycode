// Kernel writes and reads of sRGB textures (visionos.md §10.21): the back
// end gives an sRGB texture with shaderWrite a storage view in the unorm
// format of its layout and sets bit 32 of its handle; ycode-airc's storage
// writes then encode linear to sRGB and its storage reads decode, as Metal
// does. Translator/tests/ir/interface-forms.sh leaves `srgbw` translated: a
// kernel that writes linear (0.5, 0.25, 2^-9, 0.5) at its position and
// copies the texel at (1, 1), read back, into out[x]; dispatched twice.
//   YCODE_TEST_SRGBW_SPV=WORK/srgbw.spv YCODE_TEST_SRGBW_JSON=WORK/srgbw.json

import Foundation
import Testing
@testable import YcodeMetalHost
@testable import YcodeVulkan

@Suite(.serialized, .enabled(if: HangProbe.env["YCODE_TEST_SRGBW_SPV"] != nil && VK.available,
                             "needs YCODE_TEST_SRGBW_SPV, YCODE_TEST_SRGBW_JSON and a GPU"))
struct SRGBStorageGPUTests {
    @Test func kernelWritesAndReadsOfAnSRGBTextureConvert() throws {
        let spvData = try Data(contentsOf: URL(fileURLWithPath: HangProbe.env["YCODE_TEST_SRGBW_SPV"]!))
        let reflection = try ShaderReflection.decode(Data(contentsOf: URL(fileURLWithPath: HangProbe.env["YCODE_TEST_SRGBW_JSON"]!)))
        var words = [UInt32](repeating: 0, count: spvData.count / 4)
        _ = words.withUnsafeMutableBytes { spvData.copyBytes(to: $0) }
        let t = PrebuiltShaderTranslator()
        t.add(Array("srgbw".utf8), TranslatedShader(spirv: words, reflection: reflection))
        let b = VulkanMetalBackend(translator: t, options: VulkanMetalBackend.Options())
        defer { b.shutdown() }
        let fn = VK.handle(), pipe = VK.handle(), out = VK.handle()
        try b.createFunction(fn, metallib: Array("srgbw".utf8))
        _ = try b.createComputePipeline(pipe, function: fn)
        let mem = HostPages(65536)
        try b.createBuffer(out, length: 16 * 8, storage: .shared, guestMemory: mem.region(0, 16 * 8))
        // (pixel format, the bytes a write of the value stores, the value a read gives back)
        let cases: [(UInt32, [UInt8], [Float])] = [
            (MetalPixelFormat.rgba8UnormSRGB, [188, 137, 6, 128], [0.5, 0.25, 0.001953125, 0.5]),
            (MetalPixelFormat.rgba8Unorm, [128, 64, 0, 128], [128 / 255, 64 / 255, 0, 128 / 255]),
        ]
        for (format, stored, readBack) in cases {
            let tex = VK.handle()
            try b.createTexture(tex, MetalTextureDescriptor(pixelFormat: format, width: 8, height: 8, usage: 0x3, resourceOptions: 0x20),
                                iosurface: nil)
            let id = try #require(b.gpuResourceID(ofTexture: tex))
            #expect((id >> 32) == (format == MetalPixelFormat.rgba8UnormSRGB ? 1 : 0))
            let done = DispatchSemaphore(value: 0)
            let status = StatusBox()
            b.submit(MetalCommandBuffer(process: 1, queue: nil, commandBufferRef: VK.nextID(), passes: [.compute([
                .setComputePipelineState(pipe), .setBuffer(index: 0, buffer: out, offset: 0), .setTexture(index: 0, texture: tex),
                .dispatchThreads(MetalSize3(8, 8, 1), threadsPerThreadgroup: MetalSize3(8, 8, 1)),
                // Again: every thread now reads (1, 1) after the first dispatch wrote it.
                .dispatchThreads(MetalSize3(8, 8, 1), threadsPerThreadgroup: MetalSize3(8, 8, 1)),
            ])]), scheduled: {}, completed: { s in status.value = s; done.signal() })
            #expect(done.wait(timeout: .now() + 10) == .success && status.value == 4)
            try b.getBytes(texture: tex, MetalRegion(width: 8, height: 8), level: 0, slice: 0, into: mem.region(32768, 256),
                           bytesPerRow: 32, bytesPerImage: 256)
            let px = Array(mem.bytes(32768 + 4 * 9, 4))
            #expect(zip(px, stored).allSatisfy { abs(Int($0) - Int($1)) <= 1 }, "format \(format): stored \(px), expected \(stored)")
            let got = Array(mem.floats(16 * 7, 4))  // out[7] (a byte offset)
            #expect(zip(got, readBack).allSatisfy { abs($0 - $1) < 0.01 }, "format \(format): read \(got)")
            b.release(tex)
        }
        for h in [out, pipe, fn] { b.release(h) }
    }
}
