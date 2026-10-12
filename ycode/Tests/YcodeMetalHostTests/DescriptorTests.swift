import Foundation
import Testing
@testable import YcodeMetalHost

/// Fixed descriptors (spec §5) and keyed pipeline descriptors (§7).
@Suite struct DescriptorTests {
    @Test func textureDescriptorWords() throws {
        // QuartzCore display buffer pattern (§5.4): low half 0x0552, BGRA8 1398×2034.
        let words = Build.textureWords(flags: 1, usage: 5, format: 80, width: 1398, height: 2034)
        #expect(words.count == 36)
        #expect(Build.u32(words, 1) & 0xFFFF == 0x0552)
        var r = ByteReader(words)
        let d = try MetalDescriptorCodec.texture(&r)
        #expect(d.textureType == MetalTextureType.type2D && d.pixelFormat == MetalPixelFormat.bgra8Unorm)
        #expect(d.width == 1398 && d.height == 2034 && d.depth == 1 && d.mipmapLevelCount == 1 && d.sampleCount == 1)
        #expect(d.usage == MetalTextureUsage.shaderRead | MetalTextureUsage.renderTarget)
        #expect(d.flags == 1 && d.allowGPUOptimizedContents && d.storageMode == .shared)
        // The other word-1 patterns of §5.4: sampled-only surfaces, CAMetalLayer drawables, our probe's.
        for (low, flags, usage, optimized) in [(0x0142, 0, 1, true), (0x0062, 2, 0, true), (0x0542, 0, 5, true),
                                               (0x0242, 0, 2, true)] as [(UInt32, UInt8, UInt16, Bool)] {
            var rr = ByteReader(Build.textureWords(flags: UInt32(flags), gpuOptimized: optimized, usage: UInt32(usage), format: 80,
                                                   width: 4, height: 4))
            let t = try MetalDescriptorCodec.texture(&rr)
            #expect(t.flags == flags && t.usage == usage && t.allowGPUOptimizedContents == optimized && t.textureType == 2)
            #expect(Build.u32(Build.textureWords(flags: UInt32(flags), usage: UInt32(usage), format: 80, width: 4, height: 4), 1)
                    & 0xFFFF == low)
        }
        // Round trip, and a private 3D texture with mipmaps.
        var w = MetalByteWriter()
        MetalDescriptorCodec.encodeTexture(d, into: &w)
        #expect(w.bytes == words)
        let p = Build.textureWords(type: 7, gpuOptimized: false, usage: 1, format: 115, width: 16, height: 8, depth: 4, levels: 3,
                                   options: 0x20)
        r = ByteReader(p)
        let d3 = try MetalDescriptorCodec.texture(&r)
        #expect(d3.textureType == 7 && d3.depth == 4 && d3.mipmapLevelCount == 3 && d3.storageMode == .private
                && !d3.allowGPUOptimizedContents && d3.pixelFormat == MetalPixelFormat.rgba16Float)
    }

    @Test func samplerPackedWord() throws {
        // The default sampler: 0x84000000, flags 0, lod 0 and FLT_MAX (§5.5).
        var w = MetalByteWriter()
        w.u32(0); w.u32(0x8400_0000); w.u32(0); w.f32(0); w.f32(.greatestFiniteMagnitude); w.u64(0)
        let d = try MetalDescriptorCodec.sampler(w.bytes)
        #expect(d == MetalSamplerDescriptor())
        #expect(MetalDescriptorCodec.encodeSampler(d) == w.bytes)
        var s = MetalSamplerDescriptor()
        s.minFilter = 1; s.magFilter = 1; s.mipFilter = 2; s.sAddressMode = 2; s.tAddressMode = 3; s.rAddressMode = 4
        s.borderColor = 1; s.compareFunction = 1; s.maxAnisotropy = 16; s.normalizedCoordinates = false
        s.lodMinClamp = 1.5; s.lodMaxClamp = 7; s.supportArgumentBuffers = true
        let bytes = MetalDescriptorCodec.encodeSampler(s)
        #expect(bytes.count == 28)
        #expect(try MetalDescriptorCodec.sampler(bytes) == s)
        let expected: UInt32 = 1 | 1 << 2 | 1 << 5 | 2 << 8 | 3 << 12 | 4 << 16 | 1 << 20 | 2 << 24 | 16 << 26
        #expect(Build.u32(bytes, 1) == expected)
    }

    @Test func depthStencil() throws {
        var w = MetalByteWriter()
        w.u32(0); w.u32(7)
        for _ in 0..<6 { w.u32(0) }
        let d = try MetalDescriptorCodec.depthStencil(w.bytes)
        #expect(d.depthCompareFunction == 7 && !d.depthWriteEnabled && d.frontFaceStencil == nil && d.backFaceStencil == nil)
        var e = MetalDepthStencilDescriptor()
        e.depthCompareFunction = 1; e.depthWriteEnabled = true
        e.frontFaceStencil = MetalStencilDescriptor(compareFunction: 3, stencilFailureOperation: 1, depthFailureOperation: 2,
                                                    depthStencilPassOperation: 5, readMask: 0xFF, writeMask: 0x0F)
        e.backFaceStencil = MetalStencilDescriptor(compareFunction: 6, readMask: 1, writeMask: 2)
        let bytes = MetalDescriptorCodec.encodeDepthStencil(e)
        let bits: UInt32 = 1 | 8 | 0x10 | 0x20
        #expect(bytes.count == 32 && Build.u32(bytes, 1) == bits)
        #expect(try MetalDescriptorCodec.depthStencil(bytes) == e)
    }

    @Test func handBuiltRenderPipeline() throws {
        // Payload laid out by hand from §7.1: four top-level fields (label,
        // vertex 1, fragment 2, color array), the label after them, the
        // array at a 4-aligned offset, its element after the offset table.
        var p = MetalByteWriter()
        p.u8(4)
        for (k, v) in [(0, 25), (1, 1), (2, 2), (8, 32)] as [(UInt8, UInt32)] { p.u8(k); p.u8(4); p.u32(v) }
        #expect(p.bytes.count == 25)
        p.append(Array("Over".utf8) + [0])
        p.pad(to: 32)
        p.u32(1); p.u32(8)
        p.u8(5)
        for (k, v) in [(0, 0), (1, 80), (2, 1), (4, 5), (7, 5)] as [(UInt8, UInt32)] { p.u8(k); p.u8(4); p.u32(v) }
        let functions: [UInt32: MetalHandle] = [1: MetalHandle(101), 2: MetalHandle(102)]
        let d = try MetalPipelineCodec.renderPipeline(p.bytes) { functions[$0] }
        #expect(d.label == "Over" && d.vertexFunction == MetalHandle(101) && d.fragmentFunction == MetalHandle(102))
        #expect(d.colorAttachments.count == 1)
        let c = try #require(d.colorAttachments.first)
        // Premultiplied "over": source factors default One, destination OneMinusSourceAlpha (5).
        #expect(c.index == 0 && c.pixelFormat == 80 && c.blendingEnabled && c.sourceRGBBlendFactor == 1
                && c.destinationRGBBlendFactor == 5 && c.sourceAlphaBlendFactor == 1 && c.destinationAlphaBlendFactor == 5
                && c.rgbBlendOperation == 0 && c.writeMask == 0xF)
        #expect(d.vertexDescriptor == nil && d.rasterSampleCount == 1 && d.unknownKeys.isEmpty)
        // The body of op 14: u32 0, u32 payload length, payload.
        var body = MetalByteWriter()
        body.u32(0); body.u32(UInt32(p.bytes.count)); body.append(p.bytes)
        #expect(try MetalPipelineCodec.payload(body.bytes) == p.bytes)
    }

    @Test func builtRenderPipelineWithVertexDescriptor() throws {
        let payload = MetalKeyedPayloadBuilder.renderPipeline(
            top: [(1, 4), (2, 3), (4, 4), (9, 252), (10, 253), (11, 3), (12, 99)],
            colorAttachments: [[(0, 0), (1, 81)], [(0, 2), (1, 115), (9, 0x7)]],
            vertexAttributes: [[(0, 0), (1, 29), (2, 0), (3, 0)], [(0, 1), (1, 31), (2, 8), (3, 0)]],
            vertexLayouts: [[(0, 0), (3, 16)], [(0, 0), (3, 16)]])
        let d = try MetalPipelineCodec.renderPipeline(payload) { MetalHandle(UInt64($0) + 1000) }
        #expect(d.label == nil && d.vertexFunction == MetalHandle(1004) && d.fragmentFunction == MetalHandle(1003))
        #expect(d.rasterSampleCount == 4 && d.depthAttachmentPixelFormat == 252 && d.stencilAttachmentPixelFormat == 253)
        #expect(d.inputPrimitiveTopology == 3 && d.unknownKeys == [12: 99])
        #expect(d.colorAttachments.map(\.index) == [0, 2] && d.colorAttachments[1].writeMask == 7
                && d.colorAttachments[1].pixelFormat == 115)
        let vd = try #require(d.vertexDescriptor)
        #expect(vd.attributes.map(\.format) == [29, 31] && vd.attributes[1].offset == 8 && vd.attributes[1].index == 1)
        #expect(vd.layouts.count == 2 && vd.layouts[0].stride == 16 && vd.layouts[0].stepFunction == 1 && vd.layouts[0].stepRate == 1)
    }

    @Test func keyOneIsVertexKeyTwoIsFragment() throws {
        // §7.2 as corrected 2026-10-12: key 1 = vertex function, key 2 = fragment function.
        let functions: [UInt32: MetalHandle] = [5: MetalHandle(500), 9: MetalHandle(900)]
        let both = try MetalPipelineCodec.renderPipeline(MetalKeyedPayloadBuilder.object([(1, 5), (2, 9)])) { functions[$0] }
        #expect(both.vertexFunction == MetalHandle(500) && both.fragmentFunction == MetalHandle(900))
        // A vertex-only pipeline (no fragment function) sends key 1 alone.
        let vertexOnly = try MetalPipelineCodec.renderPipeline(MetalKeyedPayloadBuilder.object([(1, 5)])) { functions[$0] }
        #expect(vertexOnly.vertexFunction == MetalHandle(500) && vertexOnly.fragmentFunction == nil)
    }

    @Test func computePipelineAndMalformedPayloads() throws {
        #expect(try MetalPipelineCodec.computeFunctionRef(MetalKeyedPayloadBuilder.object([(0, 7)])) == 7)
        #expect(throws: MetalDecodeError.self) { try MetalPipelineCodec.computeFunctionRef([0]) }
        // A field of unknown type, an offset beyond the payload, a truncated object.
        #expect(throws: MetalDecodeError.self) { try MetalPipelineCodec.renderPipeline([1, 1, 3, 0, 0, 0]) { _ in nil } }
        #expect(throws: MetalDecodeError.self) {
            try MetalPipelineCodec.renderPipeline(MetalKeyedPayloadBuilder.object([(8, 400)])) { _ in nil }
        }
        #expect(throws: MetalDecodeError.self) { try MetalPipelineCodec.renderPipeline([3, 1, 4]) { _ in nil } }
    }

    @Test func recordParsing() throws {
        let r = try MetalRecord.parse(Build.record(1000) { $0.u32(5) })
        #expect(r.op == 1000 && r.body == [5, 0, 0, 0])
        #expect(throws: MetalDecodeError.self) { try MetalRecord.parse([1, 0, 0, 0, 40, 0, 0, 0]) }
        #expect(throws: MetalDecodeError.self) { try MetalRecord.parse([1, 0]) }
    }

    @Test func replaceRegionUploadSize() {
        // §5.3: a 194×237 upload of 185 892 bytes = 8 + 84 + (236 × 784 + 194 × 4).
        let pixels: Int = 236 * 784 + 194 * 4
        #expect(8 + 84 + pixels == 185_892)
        var w = MetalByteWriter()
        MetalDescriptorCodec.encodeRegionHead(.init(texture: 1, region: MetalRegion(width: 3, height: 4), level: 0, slice: 0,
                                                    bytesPerRow: 32, bytesPerImage: 128), into: &w)
        #expect(w.bytes.count == 84)
    }
}
