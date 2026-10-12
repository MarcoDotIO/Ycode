// Tests of VulkanMetalBackend through the MetalBackend API with hand-built
// command models (no protocol decoder). They need a Vulkan GPU with
// VK_EXT_external_memory_host (the Thor); elsewhere they are skipped.

import Foundation
import Testing
@testable import YcodeMetalHost
@testable import YcodeVulkan

/// Page-aligned shared anonymous memory, standing in for guest pages.
final class HostPages: @unchecked Sendable {
    let pointer: UnsafeMutableRawPointer
    let length: Int
    let id: UInt64

    init(_ length: Int) {
        self.length = length
        let p = mmap(nil, length, PROT_READ | PROT_WRITE, MAP_SHARED | MAP_ANONYMOUS, -1, 0)
        precondition(p != MAP_FAILED, "mmap failed")
        pointer = p!
        id = VK.nextID()
    }

    deinit { munmap(pointer, length) }

    func region(_ offset: Int, _ length: Int) -> GuestSharedRegion {
        GuestSharedRegion(pointer: pointer + offset, length: length, objectID: id, offset: offset,
                          objectPointer: pointer, objectLength: self.length, owner: self)
    }

    func floats(_ offset: Int, _ count: Int) -> UnsafeMutableBufferPointer<Float> {
        UnsafeMutableBufferPointer(start: (pointer + offset).bindMemory(to: Float.self, capacity: count), count: count)
    }

    func bytes(_ offset: Int, _ count: Int) -> UnsafeMutableBufferPointer<UInt8> {
        UnsafeMutableBufferPointer(start: (pointer + offset).bindMemory(to: UInt8.self, capacity: count), count: count)
    }
}

/// Shared test state: one backend (device creation is not free) and the test shaders.
enum VK {
    static let lock = NSLock()
    nonisolated(unsafe) static var counter: UInt64 = 1000

    static func nextID() -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        counter += 1
        return counter
    }

    static func handle() -> MetalHandle { MetalHandle(nextID()) }

    static let translator: PrebuiltShaderTranslator = {
        let t = PrebuiltShaderTranslator()
        t.add(Array("test:add".utf8), TranslatedShader(spirv: TestShaders.add, reflection: ShaderReflection(stage: .kernel, entryPoint: "main")))
        t.add(Array("test:fill".utf8), TranslatedShader(spirv: TestShaders.fill, reflection: ShaderReflection(stage: .kernel, entryPoint: "main")))
        t.add(Array("test:tri.vert".utf8), TranslatedShader(spirv: TestShaders.triVert, reflection: ShaderReflection(stage: .vertex, entryPoint: "main")))
        t.add(Array("test:color.frag".utf8), TranslatedShader(spirv: TestShaders.colorFrag, reflection: ShaderReflection(stage: .fragment, entryPoint: "main")))
        t.add(Array("test:full.vert".utf8), TranslatedShader(spirv: TestShaders.fullVert, reflection: ShaderReflection(stage: .vertex, entryPoint: "main")))
        t.add(Array("test:tex.frag".utf8), TranslatedShader(spirv: TestShaders.texFrag, reflection: ShaderReflection(stage: .fragment, entryPoint: "main")))
        return t
    }()

    static let backend: VulkanMetalBackend = {
        var o = VulkanMetalBackend.Options()
        o.log = { print($0) }
        return VulkanMetalBackend(translator: translator, options: o)
    }()

    static var available: Bool { backend.isAvailable }

    /// A function handle for one of the test shaders.
    static func function(_ name: String) throws -> MetalHandle {
        let h = handle()
        try backend.createFunction(h, metallib: Array("test:\(name)".utf8))
        return h
    }

    final class Completion: @unchecked Sendable {
        let lock = NSLock()
        var scheduled = false
        var scheduledBeforeCompleted = false
        var status = -1
        let done = DispatchSemaphore(value: 0)
    }

    /// Submits and waits (10 s at most). Returns the status and whether
    /// `scheduled` came before `completed`.
    @discardableResult
    static func run(_ passes: [MetalPass]) -> (status: Int, scheduledFirst: Bool) {
        let c = Completion()
        let cb = MetalCommandBuffer(process: 1, queue: nil, commandBufferRef: nextID(), passes: passes)
        backend.submit(cb, scheduled: {
            c.lock.lock(); c.scheduled = true; c.lock.unlock()
        }, completed: { status in
            c.lock.lock(); c.status = status; c.scheduledBeforeCompleted = c.scheduled; c.lock.unlock()
            c.done.signal()
        })
        if c.done.wait(timeout: .now() + 10) == .timedOut { return (-2, false) }
        c.lock.lock(); defer { c.lock.unlock() }
        return (c.status, c.scheduledBeforeCompleted)
    }

    static func texture(_ format: UInt32, _ w: Int, _ h: Int, usage: UInt16 = 0x5, private p: Bool = true,
                        iosurface: IOSurfaceBacking? = nil) throws -> MetalHandle {
        let t = handle()
        try backend.createTexture(t, MetalTextureDescriptor(pixelFormat: format, width: w, height: h, usage: usage,
                                                            resourceOptions: p ? 0x20 : 0), iosurface: iosurface)
        return t
    }

    /// Reads a texture back through getBytes (tightly packed rows).
    static func read(_ texture: MetalHandle, _ w: Int, _ h: Int, bpp: Int = 4) throws -> [UInt8] {
        let pages = HostPages(roundUp(w * h * bpp, 16384))
        try backend.getBytes(texture: texture, MetalRegion(width: w, height: h), level: 0, slice: 0,
                             into: pages.region(0, w * h * bpp), bytesPerRow: w * bpp, bytesPerImage: w * h * bpp)
        return Array(pages.bytes(0, w * h * bpp))
    }

    static func colorPass(_ texture: MetalHandle, load: UInt16 = MetalLoadAction.clear, clear: [Double] = [0, 0, 0, 1],
                          _ commands: [MetalRenderCommand] = []) -> MetalPass {
        var d = MetalRenderPassDescriptor()
        d.colorAttachments = [MetalColorAttachment(index: 0, attachment: MetalRenderPassAttachment(
            texture: texture, loadAction: load, storeAction: MetalStoreAction.store), clearColor: clear)]
        return .render(MetalRenderPass(descriptor: d, commands: commands))
    }
}

func near(_ a: UInt8, _ b: UInt8, _ tol: Int = 1) -> Bool { abs(Int(a) - Int(b)) <= tol }

@Suite(.serialized, .enabled(if: VK.available, "needs a Vulkan GPU with VK_EXT_external_memory_host"))
struct VulkanBackendTests {
    @Test func deviceAndFormats() throws {
        let b = VK.backend
        print("device: \(b.deviceName), subgroup \(b.subgroupSize), limits \(b.limits())")
        // The home-screen formats of metal-sim-protocol.md §10 must all map.
        let homeScreen: [UInt32] = [115, 80, 65, 253, 25, 10, 1, 70, 81, 71, 110, 250, 252, 92, 90]
        for f in homeScreen {
            let v = b.vulkanFormat(forMetal: f)
            #expect(v != nil, "Metal pixel format \(f)")
        }
        var supported: [String] = [], missing: [UInt32] = []
        for f: UInt32 in 0...600 where metalPixelFormatTable(f) != nil {
            if let v = b.vulkanFormat(forMetal: f) {
                supported.append("\(f)->\(v.format.rawValue)\(v.approximate ? "~" : "")")
            } else {
                missing.append(f)
            }
        }
        print("formats supported (\(supported.count)): \(supported.joined(separator: " "))")
        print("formats unsupported on this device: \(missing)")
    }

    @Test func computeOverGuestMemory() throws {
        let b = VK.backend
        let n = 1000
        // Two "guest objects": buffers at unaligned offsets inside the first.
        let guest = HostPages(65536), other = HostPages(16384)
        let aOff = 0, bOff = 8192 + 64, outOff = 16384 + 128
        for i in 0..<n {
            guest.floats(aOff, n)[i] = Float(i)
            guest.floats(bOff, n)[i] = Float(2 * i) + 0.5
            guest.floats(outOff, n)[i] = -1
        }
        other.pointer.storeBytes(of: UInt32(n - 10), toByteOffset: 8, as: UInt32.self)
        let ha = VK.handle(), hb = VK.handle(), hout = VK.handle(), hcount = VK.handle()
        try b.createBuffer(ha, length: n * 4, storage: .shared, guestMemory: guest.region(aOff, n * 4))
        try b.createBuffer(hb, length: n * 4, storage: .shared, guestMemory: guest.region(bOff, n * 4))
        try b.createBuffer(hout, length: n * 4, storage: .shared, guestMemory: guest.region(outOff, n * 4))
        try b.createBuffer(hcount, length: 4, storage: .shared, guestMemory: other.region(8, 4))
        let pipe = VK.handle()
        let info = try b.createComputePipeline(pipe, function: try VK.function("add"))
        #expect(info.threadExecutionWidth == 32 || info.threadExecutionWidth > 0)
        let r = VK.run([.compute([
            .setComputePipelineState(pipe),
            .setBuffer(index: 0, buffer: ha, offset: 0),
            .setBuffer(index: 1, buffer: hb, offset: 0),
            .setBuffer(index: 2, buffer: hout, offset: 0),
            .setBuffer(index: 3, buffer: hcount, offset: 0),
            .dispatchThreads(MetalSize3(n, 1, 1), threadsPerThreadgroup: MetalSize3(64, 1, 1)),
        ])])
        #expect(r.status == 4)
        let out = guest.floats(outOff, n)
        var bad = 0
        for i in 0..<n {
            let want: Float = i < n - 10 ? Float(i) + Float(2 * i) + 0.5 : -1
            if out[i] != want { bad += 1 }
        }
        #expect(bad == 0, "\(bad) wrong values; out[1] = \(out[1])")
        #expect(b.gpuAddress(ofBuffer: hb) == b.gpuAddress(ofBuffer: ha)! + UInt64(bOff - aOff))
        print("import: host \(guest.pointer + aOff) device 0x\(String(b.gpuAddress(ofBuffer: ha)!, radix: 16))")
        for h in [ha, hb, hout, hcount, pipe] { b.release(h) }
    }

    @Test func clearRenderTarget() throws {
        let t = try VK.texture(MetalPixelFormat.rgba8Unorm, 64, 64)
        let r = VK.run([VK.colorPass(t, clear: [0.25, 0.5, 0.75, 1])])
        #expect(r.status == 4)
        let px = try VK.read(t, 64, 64)
        var bad = 0
        for i in stride(from: 0, to: px.count, by: 4) where
            !(near(px[i], 64) && near(px[i + 1], 128) && near(px[i + 2], 191) && px[i + 3] == 255) { bad += 1 }
        #expect(bad == 0, "first pixel \(px[0..<4])")
        VK.backend.release(t)
    }

    /// A red triangle with its apex at the top of the target (Metal clip
    /// space is y-up), through a vertex descriptor and a constant buffer.
    func drawTriangle(into target: MetalHandle, format: UInt32, load: UInt16 = MetalLoadAction.clear,
                      cull: UInt64? = nil, winding: UInt64? = nil) throws -> Int {
        let b = VK.backend
        let verts = HostPages(16384)
        // float2 position + uchar4 color, stride 12.
        let positions: [(Float, Float)] = [(-1, -1), (1, -1), (0, 1)]
        for (i, p) in positions.enumerated() {
            verts.pointer.storeBytes(of: p.0, toByteOffset: 12 * i, as: Float.self)
            verts.pointer.storeBytes(of: p.1, toByteOffset: 12 * i + 4, as: Float.self)
            verts.pointer.storeBytes(of: UInt32(0xFF00_00FF), toByteOffset: 12 * i + 8, as: UInt32.self)  // r=255, a=255
        }
        let xf: [Float] = [1, 1, 0, 0]
        for (i, v) in xf.enumerated() { verts.pointer.storeBytes(of: v, toByteOffset: 4096 + 4 * i, as: Float.self) }
        let vb = VK.handle(), xb = VK.handle()
        try b.createBuffer(vb, length: 36, storage: .shared, guestMemory: verts.region(0, 36))
        try b.createBuffer(xb, length: 16, storage: .shared, guestMemory: verts.region(4096, 16))
        var desc = MetalRenderPipelineDescriptor()
        desc.vertexFunction = try VK.function("tri.vert")
        desc.fragmentFunction = try VK.function("color.frag")
        var c = MetalColorAttachmentDescriptor(index: 0)
        c.pixelFormat = format
        desc.colorAttachments = [c]
        var vd = MetalVertexDescriptor()
        var a0 = MetalVertexDescriptor.Attribute(index: 0); a0.format = 29; a0.offset = 0; a0.bufferIndex = 0
        var a1 = MetalVertexDescriptor.Attribute(index: 1); a1.format = 9; a1.offset = 8; a1.bufferIndex = 0
        var l0 = MetalVertexDescriptor.Layout(bufferIndex: 0); l0.stride = 12
        vd.attributes = [a0, a1]
        vd.layouts = [l0, l0]
        desc.vertexDescriptor = vd
        let pipe = VK.handle()
        try b.createRenderPipeline(pipe, desc)
        var cmds: [MetalRenderCommand] = [
            .setRenderPipelineState(pipe),
            .setBuffer(stage: .vertex, index: 0, buffer: vb, offset: 0),
            .setBuffer(stage: .vertex, index: 1, buffer: xb, offset: 0),
        ]
        if let w = winding { cmds.append(.setFrontFacingWinding(w)) }
        if let m = cull { cmds.append(.setCullMode(m)) }
        cmds.append(.draw(MetalDraw(primitiveType: MetalPrimitiveType.triangle, vertexStart: 0, vertexCount: 3)))
        let r = VK.run([VK.colorPass(target, load: load, cmds)])
        for h in [vb, xb, pipe] { b.release(h) }
        withExtendedLifetime(verts) {}
        return r.status
    }

    @Test func triangle() throws {
        let t = try VK.texture(MetalPixelFormat.bgra8Unorm, 64, 64)
        #expect(try drawTriangle(into: t, format: MetalPixelFormat.bgra8Unorm) == 4)
        let px = try VK.read(t, 64, 64)
        func at(_ x: Int, _ y: Int) -> [UInt8] { Array(px[4 * (y * 64 + x)..<4 * (y * 64 + x) + 4]) }
        let red: [UInt8] = [0, 0, 255, 255], black: [UInt8] = [0, 0, 0, 255]
        #expect(at(32, 2) == red, "apex (top centre) \(at(32, 2))")
        #expect(at(2, 2) == black, "top-left \(at(2, 2))")
        #expect(at(61, 2) == black, "top-right \(at(61, 2))")
        #expect(at(2, 62) == red, "bottom-left \(at(2, 62))")
        #expect(at(61, 62) == red, "bottom-right \(at(61, 62))")
        VK.backend.release(t)
    }

    /// The triangle (-1,-1), (1,-1), (0,1) is counter-clockwise on screen.
    @Test func cullingAndWinding() throws {
        let t = try VK.texture(MetalPixelFormat.rgba8Unorm, 32, 32)
        // Front = counter-clockwise, cull back: visible.
        #expect(try drawTriangle(into: t, format: MetalPixelFormat.rgba8Unorm, cull: 2, winding: 1) == 4)
        #expect(try VK.read(t, 32, 32)[4 * (28 * 32 + 16)] == 255)
        // Front = clockwise (Metal's default), cull back: culled.
        #expect(try drawTriangle(into: t, format: MetalPixelFormat.rgba8Unorm, cull: 2, winding: 0) == 4)
        #expect(try VK.read(t, 32, 32)[4 * (28 * 32 + 16)] == 0)
        VK.backend.release(t)
    }

    @Test func sampledTexture() throws {
        let b = VK.backend
        let src = try VK.texture(MetalPixelFormat.rgba8Unorm, 2, 2, usage: 1)
        let texels: [UInt8] = [255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 255, 255, 255, 255]
        try b.replaceRegion(texture: src, MetalRegion(width: 2, height: 2), level: 0, slice: 0, bytes: texels,
                            bytesPerRow: 8, bytesPerImage: 16)
        let smp = VK.handle()
        try b.createSampler(smp, MetalSamplerDescriptor())  // nearest, clamp
        var desc = MetalRenderPipelineDescriptor()
        desc.vertexFunction = try VK.function("full.vert")
        desc.fragmentFunction = try VK.function("tex.frag")
        var c = MetalColorAttachmentDescriptor(index: 0)
        c.pixelFormat = MetalPixelFormat.rgba8Unorm
        desc.colorAttachments = [c]
        let pipe = VK.handle()
        try b.createRenderPipeline(pipe, desc)
        let t = try VK.texture(MetalPixelFormat.rgba8Unorm, 64, 64)
        let r = VK.run([VK.colorPass(t, [
            .setRenderPipelineState(pipe),
            .setTexture(stage: .fragment, index: 0, texture: src),
            .setSamplerState(stage: .fragment, index: 0, sampler: smp, lodMinClamp: nil, lodMaxClamp: nil),
            .draw(MetalDraw(primitiveType: MetalPrimitiveType.triangle, vertexStart: 0, vertexCount: 3)),
        ])])
        #expect(r.status == 4)
        let px = try VK.read(t, 64, 64)
        var bad = 0
        for y in 0..<64 {
            for x in 0..<64 {
                let want = Array(texels[4 * ((y < 32 ? 0 : 2) + (x < 32 ? 0 : 1))..<4 * ((y < 32 ? 0 : 2) + (x < 32 ? 0 : 1)) + 4])
                if Array(px[4 * (y * 64 + x)..<4 * (y * 64 + x) + 4]) != want { bad += 1 }
            }
        }
        #expect(bad == 0, "\(bad) of 4096 pixels wrong")
        for h in [src, smp, pipe, t] { b.release(h) }
    }

    @Test func blits() throws {
        let b = VK.backend
        let mem = HostPages(65536)
        let pattern = mem.bytes(0, 16 * 16 * 4)
        for i in 0..<pattern.count { pattern[i] = UInt8(truncatingIfNeeded: i * 7 + 3) }
        let src = VK.handle(), dst = VK.handle(), filled = VK.handle()
        try b.createBuffer(src, length: 1024, storage: .shared, guestMemory: mem.region(0, 1024))
        try b.createBuffer(dst, length: 1024, storage: .shared, guestMemory: mem.region(16384, 1024))
        try b.createBuffer(filled, length: 64, storage: .shared, guestMemory: mem.region(32768, 64))
        mem.bytes(16384, 1024).initialize(repeating: 0)
        mem.bytes(32768, 64).initialize(repeating: 0)
        let t1 = try VK.texture(MetalPixelFormat.rgba8Unorm, 16, 16, usage: 1)
        let t2 = try VK.texture(MetalPixelFormat.rgba8Unorm, 16, 16, usage: 1)
        let r = VK.run([.blit([
            .copyBufferToTexture(source: src, sourceOffset: 0, bytesPerRow: 64, bytesPerImage: 1024, size: MetalSize3(16, 16, 1),
                                 destination: t1, slice: 0, level: 0, origin: MetalSize3(0, 0, 0), options: 0),
            .copyTextureToTexture(source: t1, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MetalSize3(0, 0, 0),
                                  size: MetalSize3(8, 8, 1), destination: t2, destinationSlice: 0, destinationLevel: 0,
                                  destinationOrigin: MetalSize3(4, 4, 0)),
            .copyTextureToBuffer(source: t2, slice: 0, level: 0, origin: MetalSize3(0, 0, 0), size: MetalSize3(16, 16, 1),
                                 destination: dst, destinationOffset: 0, bytesPerRow: 64, bytesPerImage: 1024, options: 0),
            .fillBuffer(filled, location: 3, length: 13, value: 0xAB),
            .copyBufferToBuffer(source: src, sourceOffset: 1, destination: filled, destinationOffset: 32, size: 7),
        ])])
        #expect(r.status == 4)
        let out = mem.bytes(16384, 1024)
        var bad = 0
        for y in 0..<16 {
            for x in 0..<16 {
                let inside = (4..<12).contains(x) && (4..<12).contains(y)
                for k in 0..<4 {
                    let want: UInt8 = inside ? pattern[((y - 4) * 16 + (x - 4)) * 4 + k] : 0
                    if out[(y * 16 + x) * 4 + k] != want { bad += 1 }
                }
            }
        }
        #expect(bad == 0, "\(bad) wrong bytes after buffer→texture→texture→buffer")
        let f = mem.bytes(32768, 64)
        #expect(Array(f[0..<3]) == [0, 0, 0] && f[3..<16].allSatisfy { $0 == 0xAB } && f[16] == 0)
        #expect(Array(f[32..<39]) == Array(pattern[1..<8]))
        for h in [src, dst, filled, t1, t2] { b.release(h) }
    }

    @Test func computeWritesTexture() throws {
        let b = VK.backend
        let t = try VK.texture(MetalPixelFormat.rgba8Unorm, 40, 24, usage: 0x3)
        let pipe = VK.handle()
        _ = try b.createComputePipeline(pipe, function: try VK.function("fill"))
        let r = VK.run([.compute([
            .setComputePipelineState(pipe),
            .setTexture(index: 0, texture: t),
            .dispatchThreads(MetalSize3(40, 24, 1), threadsPerThreadgroup: MetalSize3(8, 8, 1)),
        ])])
        #expect(r.status == 4)
        let px = try VK.read(t, 40, 24)
        var bad = 0
        for y in 0..<24 {
            for x in 0..<40 where !(px[4 * (y * 40 + x)] == UInt8(x) && px[4 * (y * 40 + x) + 1] == UInt8(y)) { bad += 1 }
        }
        #expect(bad == 0)
        for h in [t, pipe] { b.release(h) }
    }

    /// An IOSurface texture: the surface's pixels are read before the pass
    /// (load action Load) and the rendering is in surface memory before
    /// `scheduled`.
    @Test func ioSurfaceTexture() throws {
        let w = 64, h = 64, pitch = 320  // pitch larger than 64 × 4
        let surface = HostPages(roundUp(pitch * h, 16384))
        for y in 0..<h {
            for x in 0..<w { surface.pointer.storeBytes(of: UInt32(0xFF00_FF00), toByteOffset: y * pitch + 4 * x, as: UInt32.self) }
        }
        let backing = IOSurfaceBacking(surfaceID: 7, region: surface.region(0, pitch * h), width: w, height: h,
                                       bytesPerRow: pitch, bytesPerElement: 4, pixelFormat: 0x4247_5241)
        let t = try VK.texture(MetalPixelFormat.bgra8Unorm, w, h, usage: 0x5, private: false, iosurface: backing)
        #expect(try drawTriangle(into: t, format: MetalPixelFormat.bgra8Unorm, load: MetalLoadAction.load) == 4)
        func at(_ x: Int, _ y: Int) -> UInt32 { surface.pointer.load(fromByteOffset: y * pitch + 4 * x, as: UInt32.self) }
        #expect(at(32, 2) == 0xFFFF_0000, "apex \(hex(at(32, 2)))")   // red in BGRA
        #expect(at(2, 2) == 0xFF00_FF00, "outside \(hex(at(2, 2)))")  // green kept (loaded)
        // `scheduled` must come before `completed`.
        let r = VK.run([VK.colorPass(t, clear: [0, 0, 1, 1])])
        #expect(r.status == 4 && r.scheduledFirst)
        #expect(at(10, 10) == 0xFF00_00FF, "after clear \(hex(at(10, 10)))")
        VK.backend.release(t)
    }

    /// Asynchronous pipeline creation plus the persistent VkPipelineCache:
    /// a pipeline used right after creation waits for its build; the cache
    /// is written and a second backend loads it.
    @Test func pipelineCachePersists() throws {
        let path = NSTemporaryDirectory() + "ycode-vk-cache-\(getpid()).bin"
        defer { try? FileManager.default.removeItem(atPath: path) }
        var o = VulkanMetalBackend.Options()
        o.pipelineCachePath = path
        o.log = { print($0) }
        for round in 0..<2 {
            let b = VulkanMetalBackend(translator: VK.translator, options: o)
            let vf = VK.handle(), ff = VK.handle(), pipe = VK.handle(), t = VK.handle()
            try b.createFunction(vf, metallib: Array("test:full.vert".utf8))
            try b.createFunction(ff, metallib: Array("test:color.frag".utf8))
            var desc = MetalRenderPipelineDescriptor()
            desc.vertexFunction = vf
            desc.fragmentFunction = ff
            var c = MetalColorAttachmentDescriptor(index: 0)
            c.pixelFormat = MetalPixelFormat.rgba8Unorm
            desc.colorAttachments = [c]
            try b.createRenderPipeline(pipe, desc)  // returns before the compile is done
            try b.createTexture(t, MetalTextureDescriptor(pixelFormat: MetalPixelFormat.rgba8Unorm, width: 8, height: 8, usage: 5),
                                iosurface: nil)
            let done = DispatchSemaphore(value: 0)
            var d = MetalRenderPassDescriptor()
            d.colorAttachments = [MetalColorAttachment(index: 0, attachment: MetalRenderPassAttachment(
                texture: t, loadAction: MetalLoadAction.clear, storeAction: MetalStoreAction.store), clearColor: [0, 0, 0, 1])]
            b.submit(MetalCommandBuffer(process: 1, queue: nil, commandBufferRef: 1, passes: [.render(MetalRenderPass(descriptor: d, commands: [
                .setRenderPipelineState(pipe),
                .draw(MetalDraw(primitiveType: MetalPrimitiveType.triangle, vertexStart: 0, vertexCount: 3)),
            ]))]), scheduled: {}, completed: { _ in done.signal() })
            #expect(done.wait(timeout: .now() + 30) == .success)
            #expect(b.stats.draws == 1, "round \(round): the draw waited for its pipeline")
            b.shutdown()
            let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
            print("pipeline cache after round \(round): \(size ?? 0) bytes")
            #expect((size ?? 0) > 0)
        }
    }

    @Test func unknownHandlesAndEarlyRelease() throws {
        let b = VK.backend
        let mem = HostPages(16384)
        let buf = VK.handle()
        try b.createBuffer(buf, length: 64, storage: .shared, guestMemory: mem.region(0, 64))
        let pipe = VK.handle()
        _ = try b.createComputePipeline(pipe, function: try VK.function("fill"))
        let done = DispatchSemaphore(value: 0)
        let cb = MetalCommandBuffer(process: 1, queue: nil, commandBufferRef: 99, passes: [
            // An unknown texture handle reads as the dummy texture (heap index 0).
            .compute([.setComputePipelineState(pipe), .setTexture(index: 0, texture: MetalHandle(999_999)),
                      .setBuffer(index: 2, buffer: buf, offset: 0),
                      .dispatchThreads(MetalSize3(4, 4, 1), threadsPerThreadgroup: MetalSize3(4, 4, 1))]),
            .compute([.setComputePipelineState(MetalHandle(888_888)),
                      .dispatchThreads(MetalSize3(1, 1, 1), threadsPerThreadgroup: MetalSize3(1, 1, 1))]),
            .render(MetalRenderPass(descriptor: nil, commands: [.draw(MetalDraw(primitiveType: 3, vertexStart: 0, vertexCount: 3))])),
            .blit([.copyBufferToBuffer(source: MetalHandle(424_242), sourceOffset: 0, destination: buf, destinationOffset: 0, size: 4)]),
        ])
        b.submit(cb, scheduled: {}, completed: { s in #expect(s == 4); done.signal() })
        // Released while the command buffer may still run.
        b.release(buf)
        b.release(pipe)
        #expect(done.wait(timeout: .now() + 10) == .success)
        b.waitIdle()
        withExtendedLifetime(mem) {}
    }
}

@Suite struct VulkanBackendHostTests {
    @Test func reportsAvailability() {
        let b = VK.backend
        if !b.isAvailable {
            #expect(b.unavailableReason != nil)
            print("no Vulkan GPU: \(b.unavailableReason ?? "")")
        }
    }

    @Test func formatTable() {
        #expect(metalPixelFormatTable(MetalPixelFormat.bgra8Unorm)?.bytesPerBlock == 4)
        #expect(metalPixelFormatTable(MetalPixelFormat.rgba16Float)?.bytesPerBlock == 8)
        #expect(metalPixelFormatTable(204)?.blockWidth == 4)        // ASTC 4x4 LDR
        #expect(metalPixelFormatTable(218)?.blockHeight == 12)      // ASTC 12x12 LDR
        #expect(metalPixelFormatTable(MetalPixelFormat.depth32FloatStencil8)?.isStencil == true)
        #expect(metalVertexFormat(29) != nil && metalVertexFormat(9) != nil)
        #expect(vkColorWriteMask(0x8) == 1 && vkColorWriteMask(0xF) == 0xF)
    }

    @Test func reflectionDecodes() throws {
        // The shape of ycode-airc's reflection (ycode/Translator/src/translate.cpp).
        let json = #"{"stage":"kernel","entry_point":"k","hash":"ab12","abi":{"version":1,"push_constant_size":32,"table_push_offset":0,"table_entries":192},"buffers":[{"index":0,"table_entry":0,"used":true}],"constexpr_samplers":[{"table_entry":176,"mag_filter":"linear","s_address":"repeat"}],"constant_data":{"table_entry":31,"size":3,"base64":"AQID"},"compute":{"workgroup_size_spec_ids":[0,1,2],"grid_push_offset":16,"threadgroup_memory":{"static_bytes":0,"dynamic":true,"size_spec_id":3,"slots_base":0,"slots":[{"index":0,"offset_spec_id":100}]}},"extra":5}"#
        let r = try ShaderReflection.decode(Data(json.utf8))
        #expect(r.stage == .kernel && r.entryPoint == "k" && r.hash == "ab12")
        #expect(r.compute?.threadgroupMemory?.slots?.first?.offsetSpecId == 100)
        #expect(r.constantData?.bytes == [1, 2, 3])
        let key = SamplerKey(r.constexprSamplers![0])
        #expect(key.magFilter == 1 && key.s == 2)
    }
}

func hex(_ v: UInt32) -> String { String(v, radix: 16) }
