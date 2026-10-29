// Opt-in replay of one kernel dispatch from pass-probe dumps
// (VulkanPassProbe.swift, `YCODE_GPU_PROBE_DUMP`; visionos.md §10.20): the
// kernel's own SPIR-V and reflection (a GPU-cache entry of ycode-airc), the
// bytes of the buffers it bound, and one RGBA8 texture it writes. Prints how
// many texels the dispatch wrote and the first texel.
//
//   YCODE_TEST_REPLAY_SPV=k.spv YCODE_TEST_REPLAY_JSON=k.json \
//   YCODE_TEST_REPLAY_BUFFERS=b0.bin,b1.bin,b2.bin,b3.bin \
//   YCODE_TEST_REPLAY_TEXTURE=w,h[,levels,level] YCODE_TEST_REPLAY_GRID=w,h \
//   [YCODE_TEST_REPLAY_TG=w,h] swift test --filter ProbeReplay
//
// With `levels` and `level` the texture is a one-level view of `level` of a
// texture with `levels` levels whose level `level` is w x h (as the guest's
// mip chains are); without, a one-level texture.

import Foundation
import Testing
@testable import YcodeMetalHost
@testable import YcodeVulkan

enum ProbeReplay {
    static let env = ProcessInfo.processInfo.environment
    static var configured: Bool { env["YCODE_TEST_REPLAY_SPV"] != nil && env["YCODE_TEST_REPLAY_JSON"] != nil }
    static func ints(_ key: String) -> [Int] { (env[key] ?? "").split(separator: ",").compactMap { Int($0) } }
}

@Suite(.serialized, .enabled(if: ProbeReplay.configured && VK.available, "needs YCODE_TEST_REPLAY_SPV, YCODE_TEST_REPLAY_JSON and a GPU"))
struct ProbeReplayTests {
    @Test func replaysOneDispatch() throws {
        let env = ProbeReplay.env
        let spvData = try Data(contentsOf: URL(fileURLWithPath: env["YCODE_TEST_REPLAY_SPV"]!))
        let reflection = try ShaderReflection.decode(Data(contentsOf: URL(fileURLWithPath: env["YCODE_TEST_REPLAY_JSON"]!)))
        var words = [UInt32](repeating: 0, count: spvData.count / 4)
        _ = words.withUnsafeMutableBytes { spvData.copyBytes(to: $0) }
        let t = PrebuiltShaderTranslator()
        t.add(Array("replay:kernel".utf8), TranslatedShader(spirv: words, reflection: reflection))
        var o = VulkanMetalBackend.Options()
        o.log = { print($0) }
        let b = VulkanMetalBackend(translator: t, options: o)
        defer { b.shutdown() }
        let fn = VK.handle(), pipe = VK.handle()
        try b.createFunction(fn, metallib: Array("replay:kernel".utf8))
        _ = try b.createComputePipeline(pipe, function: fn)

        let files = (env["YCODE_TEST_REPLAY_BUFFERS"] ?? "").split(separator: ",").map(String.init)
        let datas = try files.map { try Data(contentsOf: URL(fileURLWithPath: $0)) }
        let sizes = datas.map { roundUp(max($0.count, 16), 16384) }
        let mem = HostPages(max(sizes.reduce(0, +), 16384))
        var commands: [MetalComputeCommand] = [.setComputePipelineState(pipe)]
        var handles: [MetalHandle] = []
        var off = 0
        for (i, d) in datas.enumerated() {
            d.withUnsafeBytes { (mem.pointer + off).copyMemory(from: $0.baseAddress!, byteCount: d.count) }
            let h = VK.handle()
            try b.createBuffer(h, length: max(d.count, 16), storage: .shared, guestMemory: mem.region(off, max(d.count, 16)))
            commands.append(.setBuffer(index: i, buffer: h, offset: 0))
            handles.append(h)
            off += sizes[i]
        }
        let tx = ProbeReplay.ints("YCODE_TEST_REPLAY_TEXTURE")
        let (w, h) = (tx.count > 0 ? tx[0] : 1, tx.count > 1 ? tx[1] : 1)
        let tex = VK.handle()
        var parent: MetalHandle?
        if tx.count >= 4 {
            let p = VK.handle()
            let levels = tx[2], level = tx[3]
            try b.createTexture(p, MetalTextureDescriptor(pixelFormat: MetalPixelFormat.rgba8Unorm, width: w << level, height: h << level,
                                                          mipmapLevelCount: levels, usage: 0x3, resourceOptions: 0x20), iosurface: nil)
            try b.createTextureView(tex, parent: p, MetalTextureViewDescriptor(pixelFormat: MetalPixelFormat.rgba8Unorm, levels: level..<(level + 1)))
            parent = p
        } else {
            try b.createTexture(tex, MetalTextureDescriptor(pixelFormat: MetalPixelFormat.rgba8Unorm, width: w, height: h, usage: 0x3,
                                                            resourceOptions: 0x20), iosurface: nil)
        }
        let grid = ProbeReplay.ints("YCODE_TEST_REPLAY_GRID"), tg = ProbeReplay.ints("YCODE_TEST_REPLAY_TG")
        commands.append(.setTexture(index: 0, texture: tex))
        commands.append(.dispatchThreads(MetalSize3(grid.count > 0 ? grid[0] : 1, grid.count > 1 ? grid[1] : 1, 1),
                                         threadsPerThreadgroup: MetalSize3(tg.count > 0 ? tg[0] : 32, tg.count > 1 ? tg[1] : 16, 1)))
        let done = DispatchSemaphore(value: 0)
        let status = StatusBox()
        b.submit(MetalCommandBuffer(process: 1, queue: nil, commandBufferRef: VK.nextID(), passes: [.compute(commands)]),
                 scheduled: {}, completed: { s in status.value = s; done.signal() })
        #expect(done.wait(timeout: .now() + 20) == .success, "the dispatch did not finish")
        #expect(status.value == 4)
        let out = HostPages(roundUp(w * h * 4, 16384))
        try b.getBytes(texture: tex, MetalRegion(width: w, height: h), level: 0, slice: 0, into: out.region(0, w * h * 4),
                       bytesPerRow: w * 4, bytesPerImage: w * h * 4)
        let px = out.bytes(0, w * h * 4)
        var written = 0
        for i in 0..<(w * h) where px[4 * i] | px[4 * i + 1] | px[4 * i + 2] | px[4 * i + 3] != 0 { written += 1 }
        print("probe-replay: \(written) of \(w * h) texels not zero; first texel \((0..<4).map { String(format: "%02x", px[$0]) }.joined())")
        for x in handles + [tex, pipe, fn] + (parent.map { [$0] } ?? []) { b.release(x) }
    }
}
