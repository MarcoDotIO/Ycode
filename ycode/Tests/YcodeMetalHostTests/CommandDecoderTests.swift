import Foundation
import Testing
@testable import YcodeMetalHost

/// Segments and records of a submission (spec §8), built from the layouts.
@Suite struct CommandDecoderTests {
    /// Refs map to handles 1000 × kind index + ref; ref 99 is unknown.
    static func resolve(_ kind: MetalRefKind, _ ref: UInt32) -> MetalHandle? {
        guard ref != 99 else { return nil }
        let k = UInt64(MetalRefKind.allCases.firstIndex(of: kind)!)
        return MetalHandle(1000 * k + UInt64(ref))
    }

    static func h(_ kind: MetalRefKind, _ ref: UInt32) -> MetalHandle { resolve(kind, ref)! }

    func decode(_ segments: [[UInt8]]) -> (MetalCommandBuffer, [UInt32: Int]) {
        let (cb, ops) = MetalCommandDecoder.decode(segments: segments, process: 1, queue: nil, commandBufferRef: 7,
                                                   resolve: Self.resolve)
        return (cb, ops)
    }

    /// Decoding a pass grows linearly with its records: the open pass's
    /// command list is appended to in place (it used to be copied at every
    /// append, quadratic in the commands of a pass; stage8-contract.md §15).
    @Test func longPassDecodesInLinearTime() {
        func segment(draws: Int) -> [[UInt8]] {
            var records = [Build.record(26) { $0.append(Build.renderPass(colors: [(0, 3, 2, 1, [0, 0, 0, 1])], width: 64, height: 64)) }]
            for _ in 0..<draws {
                records.append(Build.record(116) { $0.u32(4) })
                records.append(Build.record(125) { $0.u32(0); $0.u32(1); $0.u32(1); $0.u64(256) })
                records.append(Build.record(3) { $0.u16(0); $0.u16(4); $0.u16(2); $0.u16(4) })
            }
            return [Build.segment(kind: MetalEncoderKind.render, records, size: 0)]
        }
        func seconds(_ segments: [[UInt8]], rounds: Int) -> Double {
            let start = DispatchTime.now().uptimeNanoseconds
            for _ in 0..<rounds { _ = decode(segments) }
            return Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9 / Double(rounds)
        }
        let small = segment(draws: 400), large = segment(draws: 6400)
        _ = seconds(small, rounds: 3)
        let (cb, _) = decode(large)
        guard case .render(let p)? = cb.passes.first else { Issue.record("no render pass"); return }
        #expect(p.commands.count == 3 * 6400)
        let ratio = seconds(large, rounds: 3) / seconds(small, rounds: 30)
        // 16 times the records: linear is about 16, quadratic about 256.
        #expect(ratio < 64, "decode time ratio \(ratio) for 16 times the records")
    }

    /// The render records backboardd uses (§10): 26, 3, 6, 7, 110, 111, 112, 114, 116, 117, 125, 126, 130.
    func backboarddRecords() -> [[UInt8]] {
        [
            Build.record(26) { $0.append(Build.renderPass(colors: [(0, 3, 2, 1, [0.25, 0.5, 0.75, 1])], width: 1398, height: 2034)) },
            Build.record(116) { $0.u32(4) },
            Build.record(130) { w in for v in [0.0, 0, 1398, 2034, 0, 1] as [Double] { w.f64(v) } },
            Build.record(117) { w in for v in [0, 0, 1398, 2034] as [UInt64] { w.u64(v) } },
            Build.record(125) { $0.u32(0); $0.u32(1); $0.u32(1); $0.u64(256) },
            Build.record(126) { $0.u32(0); $0.u64(512) },
            Build.record(110) { $0.u32(1); $0.u32(1); $0.u32(2); $0.u64(0) },
            Build.record(111) { $0.u32(1); $0.u64(768) },
            Build.record(114) { $0.u32(0); $0.u32(1); $0.u32(5) },
            Build.record(112) { $0.u32(0); $0.u32(1); $0.u32(1) },
            Build.record(3) { $0.u16(0); $0.u16(4); $0.u16(2); $0.u16(4) },
            Build.record(7) { $0.u16(3); $0.u16(0); $0.u32(6); $0.u16(6); $0.u16(64) },
            Build.record(6) { $0.u16(3); $0.u16(1); $0.u32(6); $0.u64(70_000); $0.u64(128) },
        ]
    }

    /// The long instanced draw forms (ops 2, 4, 8; layouts from agent H's
    /// capture of our own mtlvary program, metal-sim-protocol.md §8.3) and the
    /// anomaly report for implausible draws.
    @Test func longInstancedDraws() throws {
        let records = [
            Build.record(2) { $0.u64(0); $0.u64(4); $0.u64(0x12345); $0.u32(3) },
            Build.record(4) { $0.u64(0x12345); $0.u64(4); $0.u64(2); $0.u64(0x23456); $0.u32(4) },
            Build.record(8) { $0.u16(3); $0.u16(0); $0.u32(6); $0.u64(4); $0.u64(0x10); $0.u64(0x12345) },
            // RenderBox's form: u16 instance count 0x19, base vertex 0x200.
            Build.record(9) { $0.u16(1); $0.u16(0); $0.u32(6); $0.u16(0x40); $0.u16(0); $0.u32(0x0200_0019) },
            Build.record(28) { $0.u16(4); $0.u16(0); $0.u32(6); $0.u64(0); $0.u64(4); $0.u64(3); $0.u64(0x10000); $0.u64(0) },
            Build.record(29) { $0.u16(4); $0.u16(0); $0.u32(6); $0.u16(0); $0.u16(4); $0.u16(3); $0.u16(0xFFFE); $0.u32(0) },
            Build.record(0) { $0.u32(3); $0.u64(0); $0.u64(0x0C00_0004) },
        ]
        var reports: [String] = []
        MetalCommandDecoder.anomalyLog = { reports.append($0) }
        defer { MetalCommandDecoder.anomalyLog = nil }
        let (cb, unknown) = decode([Build.segment(kind: 0, records)])
        #expect(unknown.isEmpty)
        guard case let .render(pass)? = cb.passes.first else { Issue.record("no pass"); return }
        let r = Self.h
        #expect(pass.commands == [
            .draw(MetalDraw(primitiveType: 3, vertexStart: 0, vertexCount: 4, instanceCount: 0x12345)),
            .draw(MetalDraw(primitiveType: 4, vertexStart: 0x12345, vertexCount: 4, instanceCount: 2, baseInstance: 0x23456)),
            .drawIndexed(MetalIndexedDraw(primitiveType: 3, indexType: 0, indexBuffer: r(.resource, 6), indexBufferOffset: 0x10,
                                          indexCount: 4, instanceCount: 0x12345)),
            .drawIndexed(MetalIndexedDraw(primitiveType: 1, indexType: 0, indexBuffer: r(.resource, 6), indexBufferOffset: 0,
                                          indexCount: 0x40, instanceCount: 0x19, baseVertex: 0x200)),
            .drawIndexed(MetalIndexedDraw(primitiveType: 4, indexType: 0, indexBuffer: r(.resource, 6), indexBufferOffset: 0,
                                          indexCount: 4, instanceCount: 3, baseVertex: 0x10000)),
            .drawIndexed(MetalIndexedDraw(primitiveType: 4, indexType: 0, indexBuffer: r(.resource, 6), indexBufferOffset: 0,
                                          indexCount: 4, instanceCount: 3, baseVertex: -2)),
            .draw(MetalDraw(primitiveType: 3, vertexStart: 0, vertexCount: 0x0C00_0004)),
        ])
        #expect(reports.count == 1 && reports[0].contains("op 0"))
    }

    @Test func renderEncoderAsBackboarddUsesIt() throws {
        let (cb, unknown) = decode([Build.segment(kind: 0, backboarddRecords())])
        #expect(unknown.isEmpty && cb.diagnostics.isEmpty && cb.passes.count == 1 && cb.commandBufferRef == 7)
        guard case let .render(pass)? = cb.passes.first else { Issue.record("no render pass"); return }
        let d = try #require(pass.descriptor)
        #expect(d.renderTargetWidth == 1398 && d.renderTargetHeight == 2034 && d.depth == nil && d.stencil == nil)
        #expect(d.colorAttachments.count == 1)
        let c = d.colorAttachments[0]
        #expect(c.index == 0 && c.texture == Self.h(.resource, 3) && c.attachment.loadAction == MetalLoadAction.clear
                && c.attachment.storeAction == MetalStoreAction.store && c.clearColor == [0.25, 0.5, 0.75, 1])
        #expect(cb.renderTargets == [Self.h(.resource, 3)])
        let r = Self.h
        #expect(pass.commands == [
            .setRenderPipelineState(r(.renderPipeline, 4)),
            .setViewport(MetalViewport(x: 0, y: 0, width: 1398, height: 2034, znear: 0, zfar: 1)),
            .setScissorRect(MetalScissorRect(x: 0, y: 0, width: 1398, height: 2034)),
            .setBuffer(stage: .vertex, index: 0, buffer: r(.resource, 1), offset: 256),
            .setBufferOffset(stage: .vertex, index: 0, offset: 512),
            .setBuffer(stage: .fragment, index: 1, buffer: r(.resource, 2), offset: 0),
            .setBufferOffset(stage: .fragment, index: 1, offset: 768),
            .setTexture(stage: .fragment, index: 0, texture: r(.resource, 5)),
            .setSamplerState(stage: .fragment, index: 0, sampler: r(.sampler, 1), lodMinClamp: nil, lodMaxClamp: nil),
            .draw(MetalDraw(primitiveType: 4, vertexStart: 0, vertexCount: 4, instanceCount: 2)),
            .drawIndexed(MetalIndexedDraw(primitiveType: 3, indexType: 0, indexBuffer: r(.resource, 6), indexBufferOffset: 64,
                                          indexCount: 6)),
            .drawIndexed(MetalIndexedDraw(primitiveType: 3, indexType: 1, indexBuffer: r(.resource, 6), indexBufferOffset: 128,
                                          indexCount: 70_000)),
        ])
    }

    @Test func remainingRenderRecords() {
        let records: [[UInt8]] = [
            Build.record(0) { $0.u32(3); $0.u64(70_000); $0.u64(3) },
            Build.record(1) { $0.u32(3); $0.u16(5999); $0.u16(3) },
            Build.record(5) { $0.u16(1); $0.u16(3); $0.u16(4); $0.u16(2); $0.u32(3) },
            Build.record(9) { $0.u16(3); $0.u16(0); $0.u32(6); $0.u16(12); $0.u16(0); $0.u32(9) },
            Build.record(29) { $0.u16(3); $0.u16(0); $0.u32(6); $0.u16(32); $0.u16(12); $0.u16(2); $0.u16(10); $0.u32(1) },
            Build.record(16) { $0.u64(48); $0.u32(7); $0.u32(3) },
            Build.record(17) { $0.u16(3); $0.u16(1); $0.u32(6); $0.u32(7); $0.u64(8); $0.u64(16) },
            Build.record(23) { $0.u16(1); $0.u8(2); $0.u8(4) },
            Build.record(101) { $0.f32(0.1); $0.f32(0.2); $0.f32(0.3); $0.f32(0.4) },
            Build.record(102) { $0.u32(0); $0.u32(0) },
            Build.record(104) { $0.u32(2) },
            Build.record(107) { $0.u64(2) },
            Build.record(108) { $0.f32(1); $0.f32(2); $0.f32(3) },
            Build.record(109) { $0.u64(1) },
            Build.record(113) { $0.u32(2); $0.u32(1); $0.u32(3); $0.f32(0.5); $0.f32(4) },
            Build.record(115) { $0.u64(1) },
            Build.record(119) { $0.u32(7); $0.u32(7) },
            Build.record(124) { $0.u64(1) },
            Build.record(127) { $0.u32(1); $0.u32(1); $0.u32(3) },
            Build.record(129) { $0.u32(2); $0.u32(1); $0.u32(0) },
            Build.record(135) { $0.u32(2); $0.u32(1); $0.u32(1); $0.u32(2) },
            Build.record(137) { $0.u32(1); $0.u16(3); $0.u16(2); $0.u32(5) },
        ]
        let (cb, unknown) = decode([Build.segment(kind: 0, records)])
        #expect(unknown.isEmpty)
        guard case let .render(pass)? = cb.passes.first else { Issue.record("no pass"); return }
        #expect(pass.descriptor == nil)
        let r = Self.h
        #expect(pass.commands == [
            .draw(MetalDraw(primitiveType: 3, vertexStart: 70_000, vertexCount: 3)),
            .draw(MetalDraw(primitiveType: 3, vertexStart: 5999, vertexCount: 3)),
            .draw(MetalDraw(primitiveType: 3, vertexStart: 1, vertexCount: 3, instanceCount: 4, baseInstance: 2)),
            .drawIndexed(MetalIndexedDraw(primitiveType: 3, indexType: 0, indexBuffer: r(.resource, 6), indexBufferOffset: 0,
                                          indexCount: 12, instanceCount: 9)),
            .drawIndexed(MetalIndexedDraw(primitiveType: 3, indexType: 0, indexBuffer: r(.resource, 6), indexBufferOffset: 32,
                                          indexCount: 12, instanceCount: 2, baseVertex: 10, baseInstance: 1)),
            .drawIndirect(primitiveType: 3, indirectBuffer: r(.resource, 7), indirectOffset: 48),
            .drawIndexedIndirect(primitiveType: 3, indexType: 1, indexBuffer: r(.resource, 6), indexBufferOffset: 8,
                                 indirectBuffer: r(.resource, 7), indirectOffset: 16),
            .memoryBarrier(scope: 1, afterStages: 2, beforeStages: 4),
            .setBlendColor(red: 0.1, green: 0.2, blue: 0.3, alpha: 0.4),
            .setColorStoreAction(first: 0, second: 0),
            .setDepthStencilState(r(.depthStencil, 2)),
            .setCullMode(2),
            .setDepthBias(depthBias: 1, slopeScale: 2, clamp: 3),
            .setDepthClipMode(1),
            .setSamplerState(stage: .fragment, index: 2, sampler: r(.sampler, 3), lodMinClamp: 0.5, lodMaxClamp: 4),
            .setFrontFacingWinding(1),
            .setStencilReference(front: 7, back: 7),
            .setTriangleFillMode(1),
            .setSamplerState(stage: .vertex, index: 1, sampler: r(.sampler, 3), lodMinClamp: nil, lodMaxClamp: nil),
            .setTexture(stage: .vertex, index: 2, texture: nil),
            .useResources([r(.resource, 1), r(.resource, 2)], usage: 1, stages: nil),
            .useResources([r(.resource, 5)], usage: 3, stages: 2),
        ])
    }

    @Test func continuationAcrossSegmentsAndPassOrder() {
        let begin = Build.record(26) { $0.append(Build.renderPass(colors: [(0, 3, 0, 1, [0, 0, 0, 1])], width: 4, height: 4)) }
        let draw = Build.record(1) { $0.u32(3); $0.u16(0); $0.u16(3) }
        let segments = [
            Build.segment(kind: 0, continuesInNext: true, [begin, draw]),
            Build.segment(kind: 0, continuesPrevious: true, [draw, draw]),
            Build.segment(kind: 2, [Build.record(307) { $0.u32(3) }]),
            Build.segment(kind: 3, [Build.record(401) { $0.u32(1); $0.u64(5) }]),
            Build.segment(kind: 3, [Build.record(400) { $0.u32(1); $0.u64(6) }]),
            Build.segment(kind: 0, [begin]),
        ]
        let (cb, unknown) = decode(segments)
        #expect(unknown.isEmpty && cb.diagnostics.isEmpty)
        #expect(cb.passes.count == 5)
        if case let .render(p) = cb.passes[0] { #expect(p.commands.count == 3 && p.descriptor != nil) } else { Issue.record("pass 0") }
        if case let .blit(c) = cb.passes[1] { #expect(c == [.generateMipmaps(Self.h(.resource, 3))]) } else { Issue.record("pass 1") }
        if case let .event(c) = cb.passes[2] { #expect(c == [.signal(Self.h(.event, 1), value: 5)]) } else { Issue.record("pass 2") }
        if case let .event(c) = cb.passes[3] { #expect(c == [.wait(Self.h(.event, 1), value: 6)]) } else { Issue.record("pass 3") }
        if case let .render(p) = cb.passes[4] { #expect(p.commands.isEmpty && p.descriptor != nil) } else { Issue.record("pass 4") }
    }

    @Test func computeRecords() {
        let records: [[UInt8]] = [
            Build.record(208) { $0.u32(1) },
            Build.record(203) { $0.u32(0); $0.u32(1); $0.u32(2); $0.u64(16) },
            Build.record(207) { $0.u32(0); $0.u64(32) },
            Build.record(206) { $0.u32(1); $0.u32(1); $0.u32(4) },
            Build.record(204) { $0.u32(0); $0.u32(1); $0.u32(1) },
            Build.record(205) { $0.u32(1); $0.u32(1); $0.u32(1); $0.f32(0); $0.f32(2) },
            Build.record(211) { $0.u64(1024); $0.u32(0) },
            Build.record(209) { w in for v in [0, 0, 0, 8, 8, 1] as [UInt64] { w.u64(v) } },
            Build.record(200) { w in for v in [4, 2, 1, 16, 16, 1] as [UInt64] { w.u64(v) } },
            Build.record(202) { w in for v in [100, 1, 1, 32, 1, 1] as [UInt64] { w.u64(v) } },
            Build.record(201) { w in for v in [8, 8, 1, 64] as [UInt64] { w.u64(v) }; w.u32(2) },
            Build.record(214) { $0.u32(2); $0.u32(2); $0.u32(4) },
            Build.record(215) { $0.u32(1) },
        ]
        let (cb, unknown) = decode([Build.segment(kind: 1, records)])
        #expect(unknown.isEmpty)
        guard case let .compute(c)? = cb.passes.first else { Issue.record("no compute pass"); return }
        let r = Self.h
        #expect(c == [
            .setComputePipelineState(r(.computePipeline, 1)),
            .setBuffer(index: 0, buffer: r(.resource, 2), offset: 16),
            .setBufferOffset(index: 0, offset: 32),
            .setTexture(index: 1, texture: r(.resource, 4)),
            .setSamplerState(index: 0, sampler: r(.sampler, 1), lodMinClamp: nil, lodMaxClamp: nil),
            .setSamplerState(index: 1, sampler: r(.sampler, 1), lodMinClamp: 0, lodMaxClamp: 2),
            .setThreadgroupMemoryLength(1024, index: 0),
            .setStageInRegion(origin: MetalSize3(0, 0, 0), size: MetalSize3(8, 8, 1)),
            .dispatchThreadgroups(MetalSize3(4, 2, 1), threadsPerThreadgroup: MetalSize3(16, 16, 1)),
            .dispatchThreads(MetalSize3(100, 1, 1), threadsPerThreadgroup: MetalSize3(32, 1, 1)),
            .dispatchThreadgroupsIndirect(buffer: r(.resource, 2), offset: 64, threadsPerThreadgroup: MetalSize3(8, 8, 1)),
            .memoryBarrierResources([r(.resource, 2), r(.resource, 4)]),
            .memoryBarrier(scope: 1),
        ])
    }

    @Test func blitRecords() {
        func s3(_ a: UInt64, _ b: UInt64, _ c: UInt64) -> (inout MetalByteWriter) -> Void { { $0.u64(a); $0.u64(b); $0.u64(c) } }
        let records: [[UInt8]] = [
            Build.record(300) { w in
                w.u32(1); w.u32(3); w.u64(0); w.u64(64); w.u64(1024); s3(16, 16, 1)(&w); s3(0, 0, 0)(&w); w.u16(0); w.u16(1); w.u32(0)
            },
            Build.record(301) { $0.u32(1); $0.u32(2); $0.u64(4); $0.u64(8); $0.u64(100) },
            Build.record(302) { w in
                w.u32(3); w.u32(2); s3(1, 2, 0)(&w); s3(4, 4, 1)(&w); w.u64(0); w.u64(16); w.u64(64); w.u16(0); w.u16(0); w.u32(0)
            },
            Build.record(303) { w in
                w.u32(3); w.u32(4); s3(0, 0, 0)(&w); s3(8, 8, 1)(&w); s3(2, 2, 0)(&w); w.u16(1); w.u16(0); w.u16(0); w.u16(2)
            },
            Build.record(306) { $0.u32(2); $0.u64(0); $0.u64(256); $0.u32(0xAB) },
            Build.record(309) { $0.u32(3) },
            Build.record(316) { $0.u32(1) },
            Build.record(317) { $0.u32(1) },
            Build.record(318) { $0.u32(3); $0.u32(4); $0.u16(0); $0.u16(0); $0.u16(1); $0.u16(0); $0.u16(1); $0.u16(3) },
        ]
        let (cb, unknown) = decode([Build.segment(kind: 2, records)])
        #expect(unknown.isEmpty)
        guard case let .blit(c)? = cb.passes.first else { Issue.record("no blit pass"); return }
        let r = Self.h
        #expect(c == [
            .copyBufferToTexture(source: r(.resource, 1), sourceOffset: 0, bytesPerRow: 64, bytesPerImage: 1024,
                                 size: MetalSize3(16, 16, 1), destination: r(.resource, 3), slice: 0, level: 1,
                                 origin: MetalSize3(0, 0, 0), options: 0),
            .copyBufferToBuffer(source: r(.resource, 1), sourceOffset: 4, destination: r(.resource, 2), destinationOffset: 8, size: 100),
            .copyTextureToBuffer(source: r(.resource, 3), slice: 0, level: 0, origin: MetalSize3(1, 2, 0), size: MetalSize3(4, 4, 1),
                                 destination: r(.resource, 2), destinationOffset: 0, bytesPerRow: 16, bytesPerImage: 64, options: 0),
            .copyTextureToTexture(source: r(.resource, 3), sourceSlice: 1, sourceLevel: 0, sourceOrigin: MetalSize3(0, 0, 0),
                                  size: MetalSize3(8, 8, 1), destination: r(.resource, 4), destinationSlice: 0, destinationLevel: 2,
                                  destinationOrigin: MetalSize3(2, 2, 0)),
            .fillBuffer(r(.resource, 2), location: 0, length: 256, value: 0xAB),
            .optimizeContentsForGPUAccess(r(.resource, 3)),
            .updateFence(r(.fence, 1)),
            .waitForFence(r(.fence, 1)),
            .copyTextureSlices(source: r(.resource, 3), sourceSlice: 0, sourceLevel: 0, destination: r(.resource, 4),
                               destinationSlice: 1, destinationLevel: 0, sliceCount: 1, levelCount: 3),
        ])
    }

    @Test func unknownAndMalformedRecordsNeverCrash() {
        let segments = [
            Build.segment(kind: 0, [
                Build.record(1) { $0.u32(3); $0.u16(0); $0.u16(3) },
                Build.record(999) { $0.u32(42) },  // unknown op
                Build.record(110) { $0.u32(0); $0.u32(2); $0.u32(1); $0.u32(2); $0.u64(0) },  // count 2: layout open
                Build.record(116) { $0.u32(99) },  // unknown ref
                Build.record(117) { $0.u32(1) },  // truncated body
            ]),
            Build.segment(kind: 9, [Build.record(5000)]),  // unknown encoder kind
            [0, 1],  // segment too short
            {  // a record whose length runs past `used`
                var s = Build.segment(kind: 1, [Build.record(208) { $0.u32(1) }])
                s[12] = 200
                return s
            }(),
        ]
        let (cb, unknown) = decode(segments)
        #expect(unknown == [999: 1, 110: 1, 117: 1, 5000: 1])
        #expect(cb.unknownRecordCount == 4)
        #expect(cb.diagnostics.count == 2)
        guard cb.passes.count == 3, case let .render(p) = cb.passes[0] else { Issue.record("passes \(cb.passes.count)"); return }
        #expect(p.commands.count == 5)
        #expect(p.commands[1] == .unknown(op: 999, body: [42, 0, 0, 0]))
        #expect(p.commands[3] == .setRenderPipelineState(nil))
        if case let .unknown(kind, records) = cb.passes[1] { #expect(kind == 9 && records.count == 1) } else { Issue.record("kind 9") }
        if case let .compute(c) = cb.passes[2] { #expect(c.isEmpty) } else { Issue.record("compute") }
    }

    @Test func manyDrawsAcrossTwoSegments() {
        // §8.1: a render encoder of thousands of short draws fills a 64 KiB
        // segment and continues; no record straddles segments.
        let begin = Build.record(26) { $0.append(Build.renderPass(colors: [(0, 3, 2, 1, [0, 0, 0, 1])], width: 8, height: 8)) }
        var first = [begin], second: [[UInt8]] = []
        var used = 8 + begin.count
        for i in 0..<6000 {
            let rec = Build.record(1) { $0.u32(3); $0.u16(UInt16(i)); $0.u16(3) }
            if used + rec.count <= 65536 { first.append(rec); used += rec.count } else { second.append(rec) }
        }
        let (cb, _) = decode([Build.segment(kind: 0, continuesInNext: true, first, size: 65536),
                              Build.segment(kind: 0, continuesPrevious: true, second, size: 65536)])
        guard cb.passes.count == 1, case let .render(p) = cb.passes[0] else { Issue.record("passes"); return }
        #expect(p.commands.count == 6000)
        #expect(p.commands.last == .draw(MetalDraw(primitiveType: 3, vertexStart: 5999, vertexCount: 3)))
    }
}
