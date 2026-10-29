// The weak compare-exchange atomic on the GPU (visionos.md §10.13):
// Translator/tests/ir/interface-forms.sh leaves `cas` translated, a kernel
// in which every thread adds 1 to out[0] with a compare-exchange loop whose
// `expected` lives in private memory. out[0] ends at the thread count only
// if the intrinsic's result is the success flag and a failed exchange
// refreshes `expected` (otherwise the loop never ends or counts wrongly).
//   YCODE_TEST_CAS_SPV=WORK/cas.spv YCODE_TEST_CAS_JSON=WORK/cas.json

import Foundation
import Testing
@testable import YcodeMetalHost
@testable import YcodeVulkan

@Suite(.serialized, .enabled(if: HangProbe.env["YCODE_TEST_CAS_SPV"] != nil && VK.available, "needs YCODE_TEST_CAS_SPV, YCODE_TEST_CAS_JSON and a GPU"))
struct CompareExchangeGPUTests {
    @Test func compareExchangeLoopCountsEveryThread() throws {
        let spvData = try Data(contentsOf: URL(fileURLWithPath: HangProbe.env["YCODE_TEST_CAS_SPV"]!))
        let reflection = try ShaderReflection.decode(Data(contentsOf: URL(fileURLWithPath: HangProbe.env["YCODE_TEST_CAS_JSON"]!)))
        var words = [UInt32](repeating: 0, count: spvData.count / 4)
        _ = words.withUnsafeMutableBytes { spvData.copyBytes(to: $0) }
        let t = PrebuiltShaderTranslator()
        t.add(Array("cas".utf8), TranslatedShader(spirv: words, reflection: reflection))
        let b = VulkanMetalBackend(translator: t, options: VulkanMetalBackend.Options())
        defer { b.shutdown() }
        let fn = VK.handle(), pipe = VK.handle(), hout = VK.handle(), hin = VK.handle()
        try b.createFunction(fn, metallib: Array("cas".utf8))
        _ = try b.createComputePipeline(pipe, function: fn)
        let mem = HostPages(16384)
        try b.createBuffer(hout, length: 4, storage: .shared, guestMemory: mem.region(0, 4))
        try b.createBuffer(hin, length: 4, storage: .shared, guestMemory: mem.region(8192, 4))
        for n in [64, 4096] {
            mem.pointer.storeBytes(of: UInt32(0), toByteOffset: 0, as: UInt32.self)
            let done = DispatchSemaphore(value: 0)
            let status = StatusBox()
            let cb = MetalCommandBuffer(process: 1, queue: nil, commandBufferRef: VK.nextID(), passes: [.compute([
                .setComputePipelineState(pipe),
                .setBuffer(index: 0, buffer: hout, offset: 0),
                .setBuffer(index: 1, buffer: hin, offset: 0),
                .dispatchThreads(MetalSize3(n, 1, 1), threadsPerThreadgroup: MetalSize3(64, 1, 1)),
            ])])
            b.submit(cb, scheduled: {}, completed: { s in status.value = s; done.signal() })
            guard done.wait(timeout: .now() + 10) == .success else {
                Issue.record("\(n) threads: the compare-exchange loop did not end in 10 s")
                return
            }
            #expect(status.value == 4)
            #expect(mem.pointer.load(fromByteOffset: 0, as: UInt32.self) == UInt32(n))
        }
        for h in [hout, hin, pipe, fn] { b.release(h) }
    }
}
