// The null guard on the GPU (visionos.md §10.13, metal-shaders.md §4.3):
// Translator/tests/ir/interface-forms.sh leaves `np` translated, a kernel
// that reads a pointer from in[0] and loads the u32 16 bytes past it. With
// a null pointer the load must not touch memory (on the Thor a read of
// unmapped memory stalls the GPU) and must yield 0; with a real address
// it must read through it.
//   YCODE_TEST_NULLPTR_SPV=WORK/np.spv YCODE_TEST_NULLPTR_JSON=WORK/np.json

import Foundation
import Testing
@testable import YcodeMetalHost
@testable import YcodeVulkan

@Suite(.serialized, .enabled(if: HangProbe.env["YCODE_TEST_NULLPTR_SPV"] != nil && VK.available, "needs YCODE_TEST_NULLPTR_SPV, YCODE_TEST_NULLPTR_JSON and a GPU"))
struct NullPointerGPUTests {
    @Test func nullPointerLoadReadsZeroAndRealPointerReads() throws {
        let spvData = try Data(contentsOf: URL(fileURLWithPath: HangProbe.env["YCODE_TEST_NULLPTR_SPV"]!))
        let reflection = try ShaderReflection.decode(Data(contentsOf: URL(fileURLWithPath: HangProbe.env["YCODE_TEST_NULLPTR_JSON"]!)))
        var words = [UInt32](repeating: 0, count: spvData.count / 4)
        _ = words.withUnsafeMutableBytes { spvData.copyBytes(to: $0) }
        let t = PrebuiltShaderTranslator()
        t.add(Array("np".utf8), TranslatedShader(spirv: words, reflection: reflection))
        let b = VulkanMetalBackend(translator: t, options: VulkanMetalBackend.Options())
        defer { b.shutdown() }
        let fn = VK.handle(), pipe = VK.handle(), hout = VK.handle(), hin = VK.handle()
        try b.createFunction(fn, metallib: Array("np".utf8))
        _ = try b.createComputePipeline(pipe, function: fn)
        let n = 64
        let mem = HostPages(16384)
        try b.createBuffer(hout, length: 4 * n, storage: .shared, guestMemory: mem.region(0, 4 * n))
        try b.createBuffer(hin, length: 64, storage: .shared, guestMemory: mem.region(8192, 64))
        let inAddress = try #require(b.gpuAddress(ofBuffer: hin))
        mem.pointer.storeBytes(of: UInt32(1234), toByteOffset: 8192 + 16, as: UInt32.self)
        for (pointer, want) in [(UInt64(0), UInt32(0)), (inAddress, 1234)] {
            mem.pointer.storeBytes(of: pointer, toByteOffset: 8192, as: UInt64.self)
            for i in 0..<n { mem.pointer.storeBytes(of: UInt32(0xDEAD), toByteOffset: 4 * i, as: UInt32.self) }
            let done = DispatchSemaphore(value: 0)
            let status = StatusBox()
            let cb = MetalCommandBuffer(process: 1, queue: nil, commandBufferRef: VK.nextID(), passes: [.compute([
                .setComputePipelineState(pipe),
                .setBuffer(index: 0, buffer: hout, offset: 0),
                .setBuffer(index: 1, buffer: hin, offset: 0),
                .dispatchThreads(MetalSize3(n, 1, 1), threadsPerThreadgroup: MetalSize3(64, 1, 1)),
            ])])
            b.submit(cb, scheduled: {}, completed: { s in status.value = s; done.signal() })
            guard done.wait(timeout: .now() + 5) == .success else {
                Issue.record("pointer 0x\(String(pointer, radix: 16)): the kernel did not finish in 5 s")
                return
            }
            #expect(status.value == 4)
            let bad = (0..<n).filter { mem.pointer.load(fromByteOffset: 4 * $0, as: UInt32.self) != want }.count
            #expect(bad == 0, "pointer 0x\(String(pointer, radix: 16)): \(bad) threads did not store \(want)")
        }
        for h in [hout, hin, pipe, fn] { b.release(h) }
    }
}
