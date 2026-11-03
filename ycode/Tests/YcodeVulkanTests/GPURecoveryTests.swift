// GPU hangs and device recovery (metal-sim-protocol.md §8.7,
// metal-shaders.md §4.11; agent GPU-SIRI). Each test makes its own back end:
// a hang that the fix or the watchdog does not end would stop the shared one.

import Foundation
import Testing
@testable import YcodeMetalHost
@testable import YcodeVulkan

@Suite(.serialized, .enabled(if: VK.available, "needs a Vulkan GPU with VK_EXT_external_memory_host"))
struct GPURecoveryTests {
    /// The add kernel (`out[i] = a[i] + b[i]` for i < count) with a
    /// reflection that lists its four buffers as used, as ycode-airc's does.
    static func translator() -> PrebuiltShaderTranslator {
        let t = PrebuiltShaderTranslator()
        var add = ShaderReflection(stage: .kernel, entryPoint: "main")
        add.buffers = (0..<4).map { i in
            var b = ShaderReflection.Binding(index: i)
            b.tableEntry = i
            b.used = true
            return b
        }
        t.add(Array("test:add".utf8), TranslatedShader(spirv: TestShaders.add, reflection: add))
        var spin = ShaderReflection(stage: .kernel, entryPoint: "main")
        spin.buffers = (0..<2).map { i in
            var b = ShaderReflection.Binding(index: i)
            b.used = true
            return b
        }
        t.add(Array("test:spin".utf8), TranslatedShader(spirv: TestShaders.spin, reflection: spin))
        return t
    }

    static func backend(watchdog: Double) -> VulkanMetalBackend {
        var o = VulkanMetalBackend.Options()
        o.log = { print($0) }
        o.watchdogSeconds = watchdog
        o.hangReportSeconds = 1
        return VulkanMetalBackend(translator: translator(), options: o)
    }

    final class Results: @unchecked Sendable {
        let lock = NSLock()
        var statuses: [Int: Int] = [:]
        let done = DispatchSemaphore(value: 0)
        func set(_ i: Int, _ s: Int) { lock.lock(); statuses[i] = s; lock.unlock(); done.signal() }
        func status(_ i: Int) -> Int { lock.lock(); defer { lock.unlock() }; return statuses[i] ?? -1 }
    }

    /// visionOS's Siri orb kernel reads ten buffers and its command buffer
    /// binds one; slots left unbound pointed at address 0, and that read
    /// never completes on the Thor. Now they read the dummy buffer's zeros:
    /// here the add kernel's count (buffer 3) is unbound, reads 0, and
    /// nothing is written.
    @Test func unboundBufferReadsZerosInsteadOfHanging() throws {
        let b = Self.backend(watchdog: 6)
        defer { b.shutdown() }
        let n = 256
        let guest = HostPages(65536)
        for i in 0..<n { guest.floats(0, n)[i] = 1; guest.floats(8192, n)[i] = 2; guest.floats(16384, n)[i] = -1 }
        let ha = VK.handle(), hb = VK.handle(), hout = VK.handle(), fn = VK.handle(), pipe = VK.handle()
        try b.createBuffer(ha, length: n * 4, storage: .shared, guestMemory: guest.region(0, n * 4))
        try b.createBuffer(hb, length: n * 4, storage: .shared, guestMemory: guest.region(8192, n * 4))
        try b.createBuffer(hout, length: n * 4, storage: .shared, guestMemory: guest.region(16384, n * 4))
        try b.createFunction(fn, metallib: Array("test:add".utf8))
        _ = try b.createComputePipeline(pipe, function: fn)
        let r = Results()
        b.submit(MetalCommandBuffer(process: 1, queue: nil, commandBufferRef: VK.nextID(), passes: [.compute([
            .setComputePipelineState(pipe),
            .setBuffer(index: 0, buffer: ha, offset: 0),
            .setBuffer(index: 1, buffer: hb, offset: 0),
            .setBuffer(index: 2, buffer: hout, offset: 0),
            .dispatchThreads(MetalSize3(n, 1, 1), threadsPerThreadgroup: MetalSize3(64, 1, 1)),
        ])]), scheduled: {}, completed: { r.set(0, $0) })
        #expect(r.done.wait(timeout: .now() + 4) == .success, "the dispatch did not finish in 4 s")
        #expect(r.status(0) == MetalCommandBufferStatus.completed)
        #expect(b.deviceResetCount == 0)
        #expect(b.stats.unboundBufferReads == 1)
        let untouched = (0..<n).filter { guest.floats(16384, n)[$0] == -1 }.count
        #expect(untouched == n, "count read \(n - untouched) threads past zero")
        for h in [ha, hb, hout, pipe, fn] { b.release(h) }
    }

    /// A kernel that never ends: the watchdog ends it, its command buffer
    /// fails, the device is made again, and objects made before the hang
    /// (buffers over guest memory, a texture, a pipeline) work afterwards
    /// with the same GPU address and heap slot.
    @Test func watchdogEndsAHangAndTheDeviceComesBack() throws {
        let b = Self.backend(watchdog: 2)
        defer { b.shutdown() }
        let n = 1000
        let guest = HostPages(65536)
        let flagOff = 0, spinOutOff = 64, aOff = 8192, bOff = 16384, outOff = 24576, countOff = 32768
        for i in 0..<n { guest.floats(aOff, n)[i] = Float(i); guest.floats(bOff, n)[i] = 0.5; guest.floats(outOff, n)[i] = -1 }
        guest.pointer.storeBytes(of: UInt32(n), toByteOffset: countOff, as: UInt32.self)
        let hflag = VK.handle(), hspin = VK.handle(), ha = VK.handle(), hb = VK.handle(), hout = VK.handle(), hcount = VK.handle()
        try b.createBuffer(hflag, length: 4, storage: .shared, guestMemory: guest.region(flagOff, 4))
        try b.createBuffer(hspin, length: 4, storage: .shared, guestMemory: guest.region(spinOutOff, 4))
        try b.createBuffer(ha, length: n * 4, storage: .shared, guestMemory: guest.region(aOff, n * 4))
        try b.createBuffer(hb, length: n * 4, storage: .shared, guestMemory: guest.region(bOff, n * 4))
        try b.createBuffer(hout, length: n * 4, storage: .shared, guestMemory: guest.region(outOff, n * 4))
        try b.createBuffer(hcount, length: 4, storage: .shared, guestMemory: guest.region(countOff, 4))
        let tex = VK.handle()
        try b.createTexture(tex, MetalTextureDescriptor(pixelFormat: MetalPixelFormat.rgba8Unorm, width: 32, height: 32, usage: 0x5,
                                                       resourceOptions: 0x20), iosurface: nil)
        let fspin = VK.handle(), pspin = VK.handle(), fadd = VK.handle(), padd = VK.handle()
        try b.createFunction(fspin, metallib: Array("test:spin".utf8))
        _ = try b.createComputePipeline(pspin, function: fspin)
        try b.createFunction(fadd, metallib: Array("test:add".utf8))
        _ = try b.createComputePipeline(padd, function: fadd)
        let addressBefore = b.gpuAddress(ofBuffer: ha)
        let slotBefore = b.heapSlots(ofTexture: tex)

        let r = Results()
        // The hang, and the work queued behind it on the same GPU queue.
        b.submit(MetalCommandBuffer(process: 1, queue: nil, commandBufferRef: VK.nextID(), passes: [.compute([
            .setComputePipelineState(pspin),
            .setBuffer(index: 0, buffer: hflag, offset: 0),
            .setBuffer(index: 1, buffer: hspin, offset: 0),
            .dispatchThreads(MetalSize3(1, 1, 1), threadsPerThreadgroup: MetalSize3(1, 1, 1)),
        ])]), scheduled: {}, completed: { r.set(0, $0) })
        let add = MetalCommandBuffer(process: 2, queue: nil, commandBufferRef: VK.nextID(), passes: [.compute([
            .setComputePipelineState(padd),
            .setBuffer(index: 0, buffer: ha, offset: 0),
            .setBuffer(index: 1, buffer: hb, offset: 0),
            .setBuffer(index: 2, buffer: hout, offset: 0),
            .setBuffer(index: 3, buffer: hcount, offset: 0),
            .dispatchThreads(MetalSize3(n, 1, 1), threadsPerThreadgroup: MetalSize3(64, 1, 1)),
        ])])
        b.submit(add, scheduled: {}, completed: { r.set(1, $0) })
        let deadline = DispatchTime.now() + 30
        _ = r.done.wait(timeout: deadline)
        _ = r.done.wait(timeout: deadline)
        // Whatever happened, let a kernel that is still running end.
        guest.pointer.storeBytes(of: UInt32(1), toByteOffset: flagOff, as: UInt32.self)
        #expect(r.status(0) == MetalCommandBufferStatus.error, "the hung command buffer: status \(r.status(0))")
        #expect(r.status(1) == MetalCommandBufferStatus.completed, "the queued command buffer: status \(r.status(1))")
        #expect(b.deviceResetCount == 1)
        #expect(b.lastDeviceResetReport.contains("after the watchdog"), "\(b.lastDeviceResetReport)")
        let bad = (0..<n).filter { guest.floats(outOff, n)[$0] != Float($0) + 0.5 }.count
        #expect(bad == 0, "the queued command buffer, run again on the new device: \(bad) wrong values")
        if b.ctx.pointee.features.bufferCaptureReplay != 0 {
            #expect(b.gpuAddress(ofBuffer: ha) == addressBefore, "capture replay keeps the buffer's GPU address")
        }
        #expect(b.heapSlots(ofTexture: tex)?.index == slotBefore?.index, "the texture keeps its heap slot")

        // New work on the new device, with the same objects.
        for i in 0..<n { guest.floats(outOff, n)[i] = -1; guest.floats(bOff, n)[i] = 2 }
        b.submit(add, scheduled: {}, completed: { r.set(2, $0) })
        #expect(r.done.wait(timeout: .now() + 10) == .success)
        #expect(r.status(2) == MetalCommandBufferStatus.completed)
        let bad2 = (0..<n).filter { guest.floats(outOff, n)[$0] != Float($0) + 2 }.count
        #expect(bad2 == 0, "after the reset: \(bad2) wrong values")
        #expect(b.deviceResetCount == 1)
        for h in [hflag, hspin, ha, hb, hout, hcount, tex, pspin, fspin, padd, fadd] { b.release(h) }
    }

    /// With recovery off (`YCODE_GPU_RECOVER=0`) the watchdog still ends the
    /// hang, but the device stays lost: later work fails, as before.
    @Test func withoutRecoveryTheDeviceStaysLost() throws {
        var o = VulkanMetalBackend.Options()
        o.log = { print($0) }
        o.watchdogSeconds = 2
        o.recoverDevice = false
        let b = VulkanMetalBackend(translator: Self.translator(), options: o)
        defer { b.shutdown() }
        let guest = HostPages(16384)
        let hflag = VK.handle(), hspin = VK.handle(), fspin = VK.handle(), pspin = VK.handle()
        try b.createBuffer(hflag, length: 4, storage: .shared, guestMemory: guest.region(0, 4))
        try b.createBuffer(hspin, length: 4, storage: .shared, guestMemory: guest.region(64, 4))
        try b.createFunction(fspin, metallib: Array("test:spin".utf8))
        _ = try b.createComputePipeline(pspin, function: fspin)
        let r = Results()
        let spin = MetalCommandBuffer(process: 1, queue: nil, commandBufferRef: VK.nextID(), passes: [.compute([
            .setComputePipelineState(pspin),
            .setBuffer(index: 0, buffer: hflag, offset: 0),
            .setBuffer(index: 1, buffer: hspin, offset: 0),
            .dispatchThreads(MetalSize3(1, 1, 1), threadsPerThreadgroup: MetalSize3(1, 1, 1)),
        ])])
        b.submit(spin, scheduled: {}, completed: { r.set(0, $0) })
        _ = r.done.wait(timeout: .now() + 20)
        guest.pointer.storeBytes(of: UInt32(1), toByteOffset: 0, as: UInt32.self)
        #expect(r.status(0) == MetalCommandBufferStatus.error)
        b.submit(spin, scheduled: {}, completed: { r.set(1, $0) })
        #expect(r.done.wait(timeout: .now() + 5) == .success)
        #expect(r.status(1) == MetalCommandBufferStatus.error)
        #expect(b.deviceResetCount == 0)
    }

    /// visionOS backboardd's immersion pass (XR-VIEWER's run x8): two
    /// colour attachments of different sizes (172 × 172 and 16 × 16) cleared
    /// and drawn in one pass. A render area of the larger one wrote past the
    /// smaller image and never completed on the Thor; the pass is now
    /// rendered at the smallest attachment's size.
    @Test func attachmentsOfDifferentSizesStayInsideTheSmallest() throws {
        let b = Self.backend(watchdog: 6)
        defer { b.shutdown() }
        let big = VK.handle(), small = VK.handle()
        try b.createTexture(big, MetalTextureDescriptor(pixelFormat: MetalPixelFormat.rgba8Unorm, width: 172, height: 172,
                                                       usage: 0x5, resourceOptions: 0x20), iosurface: nil)
        try b.createTexture(small, MetalTextureDescriptor(pixelFormat: MetalPixelFormat.rgba8Unorm, width: 16, height: 16,
                                                         usage: 0x5, resourceOptions: 0x20), iosurface: nil)
        var d = MetalRenderPassDescriptor()
        d.colorAttachments = [
            MetalColorAttachment(index: 0, attachment: MetalRenderPassAttachment(texture: big, loadAction: MetalLoadAction.clear,
                                                                                 storeAction: MetalStoreAction.store), clearColor: [1, 0, 0, 1]),
            MetalColorAttachment(index: 1, attachment: MetalRenderPassAttachment(texture: small, loadAction: MetalLoadAction.clear,
                                                                                 storeAction: MetalStoreAction.store), clearColor: [0, 1, 0, 1]),
        ]
        let r = Results()
        b.submit(MetalCommandBuffer(process: 1, queue: nil, commandBufferRef: VK.nextID(),
                                    passes: [.render(MetalRenderPass(descriptor: d, commands: []))]),
                 scheduled: {}, completed: { r.set(0, $0) })
        #expect(r.done.wait(timeout: .now() + 4) == .success, "the pass did not finish in 4 s")
        #expect(r.status(0) == MetalCommandBufferStatus.completed)
        #expect(b.deviceResetCount == 0)
        #expect(b.stats.mixedSizePasses == 1)
        let pages = HostPages(16384)
        try b.getBytes(texture: small, MetalRegion(width: 16, height: 16), level: 0, slice: 0,
                       into: pages.region(0, 16 * 16 * 4), bytesPerRow: 64, bytesPerImage: 1024)
        let px = pages.bytes(0, 1024)
        let green = stride(from: 0, to: 1024, by: 4).filter { px[$0] == 0 && px[$0 + 1] == 255 && px[$0 + 3] == 255 }.count
        #expect(green == 256, "the small attachment's clear: \(green) of 256 texels")
        b.release(big)
        b.release(small)
    }
}
