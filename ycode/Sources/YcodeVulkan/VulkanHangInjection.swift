// Debugging: a GPU hang on demand (metal-sim-protocol.md §8.8). With
// `YCODE_GPU_INJECT_HANG=<name>@<seconds>[x<count>]` the first command
// buffer of a client whose name (Options.describeProcess) contains <name>,
// submitted at least <seconds> after the back end started, gets a kernel
// in front of its work that never ends; <count> times (default 1), at
// least 15 s apart. It
// checks in a real boot that one client's stuck submission does not stop
// the others (the blocking watchdog ends it, its client's command buffers
// fail, and after `revokeAfterHangs` hangs the client loses GPU access).

import Foundation
import YcodeMetalHost

extension VulkanMetalBackend {
    /// The armed injection (parsed once at start; nil: off).
    struct HangInjection {
        var name: String
        var afterNs: UInt64
        var remaining: Int
        /// When the last kernel went in (monotonic ns): the next one waits
        /// `spacingNs`, so that each hang is ended before the next one
        /// (otherwise the reset fails the queued ones with the first).
        var lastAt: UInt64 = 0
        let spacingNs: UInt64 = 15_000_000_000
        let function = MetalHandle(0xFFFF_FFFF_FFFF_FF01)
        let pipeline = MetalHandle(0xFFFF_FFFF_FFFF_FF02)

        init?(_ spec: String?) {
            guard let spec, let at = spec.firstIndex(of: "@") else { return nil }
            name = String(spec[..<at])
            let rest = spec[spec.index(after: at)...].split(separator: "x", maxSplits: 1)
            guard !name.isEmpty, let s = rest.first.flatMap({ Double($0) }) else { return nil }
            afterNs = UInt64(max(s, 0) * 1e9)
            remaining = rest.count > 1 ? Int(rest[1]) ?? 1 : 1
        }
    }

    /// Our own kernel that spins until buffer 0's first word is 1 (GLSL in
    /// the test sources, TestShaders.spin); unbound, buffer 0 is the dummy
    /// buffer's zeros, so it never ends.
    static let hangKernel: [UInt32] = [
        0x07230203, 0x00010600, 0x0008000b, 0x0000004c, 0x00000000, 0x00020011, 0x00000001, 0x00020011,
        0x0000000b, 0x00020011, 0x000014e3, 0x0006000b, 0x00000001, 0x4c534c47, 0x6474732e, 0x3035342e,
        0x00000000, 0x0003000e, 0x000014e4, 0x00000001, 0x0009000f, 0x00000005, 0x00000004, 0x6e69616d,
        0x00000000, 0x00000015, 0x0000003e, 0x00000042, 0x00000046, 0x0006014b, 0x00000004, 0x00000026,
        0x00000007, 0x00000008, 0x00000009, 0x00030003, 0x00000002, 0x000001cc, 0x00070004, 0x455f4c47,
        0x625f5458, 0x65666675, 0x65725f72, 0x65726566, 0x0065636e, 0x00080004, 0x455f4c47, 0x6e5f5458,
        0x6e756e6f, 0x726f6669, 0x75715f6d, 0x66696c61, 0x00726569, 0x000d0004, 0x455f4c47, 0x735f5458,
        0x65646168, 0x78655f72, 0x63696c70, 0x615f7469, 0x68746972, 0x6974656d, 0x79745f63, 0x5f736570,
        0x36746e69, 0x00000034, 0x000a0004, 0x475f4c47, 0x4c474f4f, 0x70635f45, 0x74735f70, 0x5f656c79,
        0x656e696c, 0x7269645f, 0x69746365, 0x00006576, 0x00080004, 0x475f4c47, 0x4c474f4f, 0x6e695f45,
        0x64756c63, 0x69645f65, 0x74636572, 0x00657669, 0x00040005, 0x00000004, 0x6e69616d, 0x00000000,
        0x00050005, 0x0000000e, 0x54677241, 0x656c6261, 0x00000000, 0x00040006, 0x0000000e, 0x00000000,
        0x00000065, 0x00030005, 0x00000010, 0x00000074, 0x00030005, 0x00000013, 0x00004350, 0x00040006,
        0x00000013, 0x00000000, 0x00007376, 0x00040006, 0x00000013, 0x00000001, 0x00007366, 0x00050006,
        0x00000013, 0x00000002, 0x64697267, 0x00000000, 0x00060006, 0x00000013, 0x00000003, 0x65736572,
        0x64657672, 0x00000000, 0x00030005, 0x00000015, 0x00006370, 0x00030005, 0x0000001d, 0x0000006e,
        0x00030005, 0x00000029, 0x00323355, 0x00040006, 0x00000029, 0x00000000, 0x00000076, 0x00060005,
        0x0000003e, 0x70616568, 0x74786554, 0x73657275, 0x00004432, 0x00060005, 0x00000042, 0x70616568,
        0x67616d49, 0x44327365, 0x00000000, 0x00060005, 0x00000046, 0x70616568, 0x706d6153, 0x7372656c,
        0x00000000, 0x00040047, 0x00000007, 0x00000001, 0x00000000, 0x00040047, 0x00000008, 0x00000001,
        0x00000001, 0x00040047, 0x00000009, 0x00000001, 0x00000002, 0x00040047, 0x0000000d, 0x00000006,
        0x00000008, 0x00030047, 0x0000000e, 0x00000002, 0x00040048, 0x0000000e, 0x00000000, 0x00000018,
        0x00050048, 0x0000000e, 0x00000000, 0x00000023, 0x00000000, 0x00030047, 0x00000010, 0x000014ec,
        0x00040047, 0x00000012, 0x00000006, 0x00000004, 0x00030047, 0x00000013, 0x00000002, 0x00050048,
        0x00000013, 0x00000000, 0x00000023, 0x00000000, 0x00050048, 0x00000013, 0x00000001, 0x00000023,
        0x00000008, 0x00050048, 0x00000013, 0x00000002, 0x00000023, 0x00000010, 0x00050048, 0x00000013,
        0x00000003, 0x00000023, 0x0000001c, 0x00030047, 0x00000029, 0x00000002, 0x00040048, 0x00000029,
        0x00000000, 0x00000017, 0x00050048, 0x00000029, 0x00000000, 0x00000023, 0x00000000, 0x00040047,
        0x0000003e, 0x00000021, 0x00000000, 0x00040047, 0x0000003e, 0x00000022, 0x00000000, 0x00040047,
        0x00000042, 0x00000021, 0x00000001, 0x00040047, 0x00000042, 0x00000022, 0x00000000, 0x00040047,
        0x00000046, 0x00000021, 0x00000002, 0x00040047, 0x00000046, 0x00000022, 0x00000000, 0x00040047,
        0x00000047, 0x00000001, 0x00000000, 0x00040047, 0x00000048, 0x00000001, 0x00000001, 0x00040047,
        0x00000049, 0x00000001, 0x00000002, 0x00020013, 0x00000002, 0x00030021, 0x00000003, 0x00000002,
        0x00040015, 0x00000006, 0x00000020, 0x00000000, 0x00040032, 0x00000006, 0x00000007, 0x00000001,
        0x00040032, 0x00000006, 0x00000008, 0x00000001, 0x00040032, 0x00000006, 0x00000009, 0x00000001,
        0x00030027, 0x0000000a, 0x000014e5, 0x00040015, 0x0000000b, 0x00000040, 0x00000000, 0x0004002b,
        0x00000006, 0x0000000c, 0x000000c0, 0x0004001c, 0x0000000d, 0x0000000b, 0x0000000c, 0x0003001e,
        0x0000000e, 0x0000000d, 0x00040020, 0x0000000a, 0x000014e5, 0x0000000e, 0x00040020, 0x0000000f,
        0x00000007, 0x0000000a, 0x0004002b, 0x00000006, 0x00000011, 0x00000003, 0x0004001c, 0x00000012,
        0x00000006, 0x00000011, 0x0006001e, 0x00000013, 0x0000000b, 0x0000000b, 0x00000012, 0x00000006,
        0x00040020, 0x00000014, 0x00000009, 0x00000013, 0x0004003b, 0x00000014, 0x00000015, 0x00000009,
        0x00040015, 0x00000016, 0x00000020, 0x00000001, 0x0004002b, 0x00000016, 0x00000017, 0x00000000,
        0x00040020, 0x00000018, 0x00000009, 0x0000000b, 0x00040020, 0x0000001c, 0x00000007, 0x00000006,
        0x0004002b, 0x00000006, 0x0000001e, 0x00000000, 0x00040020, 0x00000025, 0x000014e5, 0x0000000b,
        0x00030027, 0x00000028, 0x000014e5, 0x0003001e, 0x00000029, 0x00000006, 0x00040020, 0x00000028,
        0x000014e5, 0x00000029, 0x00040020, 0x0000002b, 0x000014e5, 0x00000006, 0x0004002b, 0x00000006,
        0x0000002e, 0x00000001, 0x00020014, 0x0000002f, 0x0004002b, 0x00000016, 0x00000032, 0x00000001,
        0x00030016, 0x0000003a, 0x00000020, 0x00090019, 0x0000003b, 0x0000003a, 0x00000001, 0x00000000,
        0x00000000, 0x00000000, 0x00000001, 0x00000000, 0x0004001c, 0x0000003c, 0x0000003b, 0x0000002e,
        0x00040020, 0x0000003d, 0x00000000, 0x0000003c, 0x0004003b, 0x0000003d, 0x0000003e, 0x00000000,
        0x00090019, 0x0000003f, 0x0000003a, 0x00000001, 0x00000000, 0x00000000, 0x00000000, 0x00000002,
        0x00000004, 0x0004001c, 0x00000040, 0x0000003f, 0x0000002e, 0x00040020, 0x00000041, 0x00000000,
        0x00000040, 0x0004003b, 0x00000041, 0x00000042, 0x00000000, 0x0002001a, 0x00000043, 0x0004001c,
        0x00000044, 0x00000043, 0x0000002e, 0x00040020, 0x00000045, 0x00000000, 0x00000044, 0x0004003b,
        0x00000045, 0x00000046, 0x00000000, 0x00040032, 0x00000006, 0x00000047, 0x00000001, 0x00040032,
        0x00000006, 0x00000048, 0x00000001, 0x00040032, 0x00000006, 0x00000049, 0x00000001, 0x00040017,
        0x0000004a, 0x00000006, 0x00000003, 0x00060033, 0x0000004a, 0x0000004b, 0x00000047, 0x00000048,
        0x00000049, 0x00050036, 0x00000002, 0x00000004, 0x00000000, 0x00000003, 0x000200f8, 0x00000005,
        0x0004003b, 0x0000000f, 0x00000010, 0x00000007, 0x0004003b, 0x0000001c, 0x0000001d, 0x00000007,
        0x00050041, 0x00000018, 0x00000019, 0x00000015, 0x00000017, 0x0004003d, 0x0000000b, 0x0000001a,
        0x00000019, 0x00040078, 0x0000000a, 0x0000001b, 0x0000001a, 0x0003003e, 0x00000010, 0x0000001b,
        0x0003003e, 0x0000001d, 0x0000001e, 0x000200f9, 0x0000001f, 0x000200f8, 0x0000001f, 0x000400f6,
        0x00000021, 0x00000022, 0x00000000, 0x000200f9, 0x00000023, 0x000200f8, 0x00000023, 0x0004003d,
        0x0000000a, 0x00000024, 0x00000010, 0x00060041, 0x00000025, 0x00000026, 0x00000024, 0x00000017,
        0x00000017, 0x0006003d, 0x0000000b, 0x00000027, 0x00000026, 0x00000002, 0x00000008, 0x00040078,
        0x00000028, 0x0000002a, 0x00000027, 0x00050041, 0x0000002b, 0x0000002c, 0x0000002a, 0x00000017,
        0x0006003d, 0x00000006, 0x0000002d, 0x0000002c, 0x00000002, 0x00000004, 0x000500ab, 0x0000002f,
        0x00000030, 0x0000002d, 0x0000002e, 0x000400fa, 0x00000030, 0x00000020, 0x00000021, 0x000200f8,
        0x00000020, 0x0004003d, 0x00000006, 0x00000031, 0x0000001d, 0x00050080, 0x00000006, 0x00000033,
        0x00000031, 0x00000032, 0x0003003e, 0x0000001d, 0x00000033, 0x000200f9, 0x00000022, 0x000200f8,
        0x00000022, 0x000200f9, 0x0000001f, 0x000200f8, 0x00000021, 0x0004003d, 0x0000000a, 0x00000034,
        0x00000010, 0x00060041, 0x00000025, 0x00000035, 0x00000034, 0x00000017, 0x00000032, 0x0006003d,
        0x0000000b, 0x00000036, 0x00000035, 0x00000002, 0x00000008, 0x00040078, 0x00000028, 0x00000037,
        0x00000036, 0x0004003d, 0x00000006, 0x00000038, 0x0000001d, 0x00050041, 0x0000002b, 0x00000039,
        0x00000037, 0x00000017, 0x0005003e, 0x00000039, 0x00000038, 0x00000002, 0x00000004, 0x000100fd,
        0x00010038,
    ]

    /// Makes the injection's function and pipeline (at start, when armed).
    func prepareHangInjection() {
        guard let inj = hangInjection else { return }
        var reflection = ShaderReflection(stage: .kernel, entryPoint: "main")
        reflection.buffers = (0..<2).map { i in
            var b = ShaderReflection.Binding(index: i)
            b.used = true
            return b
        }
        let metallib = Array("ycode:inject-hang".utf8)
        let key = TranslationKey(hash: fnv1a64(metallib), count: metallib.count, linked: 0, linkedCount: -1)
        translationLock.lock()
        translations[key] = TranslatedShader(spirv: Self.hangKernel, reflection: reflection)
        translationLock.unlock()
        do {
            try createFunction(inj.function, metallib: metallib)
            _ = try createComputePipeline(inj.pipeline, function: inj.function)
            log("hang injection armed: \(inj.remaining) × a kernel that never ends in front of a command buffer of '\(inj.name)' "
                + "from \(Double(inj.afterNs) / 1e9) s")
        } catch {
            log("hang injection: \(error)")
            hangInjection = nil
        }
    }

    /// The command buffer, with the never-ending kernel in front when the
    /// injection is armed and due for this client. Not under the lock.
    func injectHang(_ mcb: MetalCommandBuffer) -> MetalCommandBuffer {
        cond.lock()
        let now = DispatchTime.now().uptimeNanoseconds
        guard let inj = hangInjection, inj.remaining > 0, now &- startedAt >= inj.afterNs,
              inj.lastAt == 0 || now &- inj.lastAt >= inj.spacingNs else { cond.unlock(); return mcb }
        cond.unlock()
        guard describeClient(mcb.process).contains(inj.name) else { return mcb }
        cond.lock()
        guard var armed = hangInjection, armed.remaining > 0 else { cond.unlock(); return mcb }
        armed.remaining -= 1
        armed.lastAt = DispatchTime.now().uptimeNanoseconds
        hangInjection = armed
        cond.unlock()
        log("hang injection: a kernel that never ends goes in front of command buffer \(mcb.commandBufferRef) of \(describeClient(mcb.process))")
        var out = mcb
        out.passes.insert(.compute([
            .setComputePipelineState(inj.pipeline),
            .dispatchThreads(MetalSize3(1, 1, 1), threadsPerThreadgroup: MetalSize3(1, 1, 1)),
        ]), at: 0)
        return out
    }
}
