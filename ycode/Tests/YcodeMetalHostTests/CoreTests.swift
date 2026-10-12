import Foundation
import Testing
@testable import YcodeMetalHost
import YcodeXPC

/// The service logic (spec §2–§9) driven with synthetic messages.
@Suite struct CoreTests {
    final class Fixture {
        let backend: NullBackend
        let memory = FakeMemory()
        let surfaces = FakeSurfaces()
        let transport = FakeTransport()
        let core: MetalHostCore
        var logs: [String] = []
        let logLock = NSLock()

        init(completesImmediately: Bool = true) {
            backend = NullBackend(completesImmediately: completesImmediately)
            var sink: ((String) -> Void)?
            core = MetalHostCore(backend: backend, memory: memory, surfaces: surfaces, log: { sink?($0) })
            sink = { [unowned self] line in logLock.withLock { logs.append(line) } }
            core.transport = transport
        }

        /// Opens the three connections (ports 0x100 + type, event port 0x200) and returns the processRef.
        @discardableResult
        func connect(base: UInt32 = 0x100, eventPort: UInt32 = 0x200) -> UInt64 {
            var processRef: UInt64 = 0
            for type in 0..<3 as Range<UInt32> {
                core.connectionOpened(base + type, clientPort: type == 0 ? eventPort : eventPort + type)
                let r = core.handle(["messageType": .uint64(0), "version": .uint64(1), "connectionType": .uint64(UInt64(type)),
                                     "processRef": .uint64(processRef)], connection: base + type).reply!
                #expect(r["version"]?.uint64Value == 10 && r["hostFeatureProfile"]?.uint64Value == 10
                        && r["registryID"]?.uint64Value != nil)
                if type == 0 { processRef = r["processRef"]!.uint64Value! } else { #expect(r["processRef"]?.uint64Value == processRef) }
            }
            return processRef
        }

        func send(_ d: XPCDict, on type: UInt32, base: UInt32 = 0x100) -> MetalHostCore.Outcome {
            core.handle(d, connection: base + type)
        }

        func replyData(_ d: XPCDict, on type: UInt32 = 1) -> [UInt8] { send(d, on: type).reply?["replyData"]?.dataValue ?? [] }
    }

    @Test func handshakeBindsThreeConnectionsPerProcess() {
        let f = Fixture()
        let a = f.connect()
        let b = f.connect(base: 0x300, eventPort: 0x400)
        #expect(a != b)
        #expect(f.core.statistics.processes == 2)
        // A message before the hand-shake gets an empty reply.
        f.core.connectionOpened(0x999, clientPort: 0)
        #expect(f.core.handle(["messageType": .uint64(7)], connection: 0x999).reply == [:])
        // The process ends with its last connection.
        f.core.connectionClosed(0x100)
        f.core.connectionClosed(0x101)
        #expect(f.core.statistics.processes == 2)
        f.core.connectionClosed(0x102)
        #expect(f.core.statistics.processes == 1)
    }

    @Test func buffersTexturesShareRefsAndRefsAreReused() throws {
        let f = Fixture()
        f.connect()
        let (shm, block) = f.memory.entry(length: 16384)
        let shared = f.send(["messageType": .uint64(1), "length": .uint64(100), "options": .uint64(0), "bufferIndex": .uint64(0),
                             "sharedMem": .sharedMemory(size: 16384, port: XPCPort(name: shm, disposition: 17))], on: 1)
        #expect(shared.reply?["bufferRef"]?.uint64Value == 1 && shared.retained == [shm])
        let priv = f.send(["messageType": .uint64(1), "length": .uint64(4096), "options": .uint64(0x20), "bufferIndex": .uint64(0)], on: 1)
        #expect(priv.reply?["bufferRef"]?.uint64Value == 2 && priv.retained.isEmpty)
        // A texture after two buffers gets ref 3 (§3); reply u32 ref.
        let tex = Build.record(1) { $0.append(Build.textureWords(usage: 5, format: 80, width: 64, height: 32)) }
        #expect(f.replyData(Build.message(8, tex)) == [3, 0, 0, 0])
        // Samplers and depth-stencil states count on their own.
        let sampler = Build.record(3) { $0.append(MetalDescriptorCodec.encodeSampler(MetalSamplerDescriptor())) }
        #expect(f.replyData(Build.message(8, sampler)) == [1, 0, 0, 0])
        let ds = Build.record(4) { $0.append(MetalDescriptorCodec.encodeDepthStencil(MetalDepthStencilDescriptor())) }
        #expect(f.replyData(Build.message(8, ds)) == [1, 0, 0, 0])
        let calls = f.backend.calls
        guard calls.count == 5, case let .createBuffer(h1, 100, .shared, true) = calls[0],
              case let .createBuffer(h2, 4096, .private, false) = calls[1],
              case let .createTexture(h3, desc, nil) = calls[2] else {
            Issue.record("calls \(calls)")
            return
        }
        #expect(desc.width == 64 && desc.pixelFormat == 80 && Set([h1, h2, h3]).count == 3)
        // Release the texture (1001) and create again: ref 3 again, new handle.
        _ = f.send(Build.message(14, Build.record(1001) { $0.u32(3) }), on: 1)
        #expect(f.backend.calls.last == .release(h3))
        #expect(f.replyData(Build.message(8, tex)) == [3, 0, 0, 0])
        if case let .createTexture(h4, _, _) = f.backend.calls.last { #expect(h4 != h3) } else { Issue.record("no texture") }
        // Releasing the shared buffer drops its memory right.
        _ = f.send(Build.message(14, Build.record(1000) { $0.u32(1) }), on: 1)
        #expect(f.transport.dropped == [shm] && f.backend.calls.last == .release(h1))
        _ = block
    }

    @Test func functionsPipelinesAndDeviceOps() throws {
        let f = Fixture()
        f.connect()
        // messageType 15: functionIR + op 15 with three u32 0; reply u32 ref, u32 0.
        let fn = Build.record(15) { $0.u32(0); $0.u32(0); $0.u32(0) }
        let ir = [UInt8](repeating: 0x4D, count: 3000)
        #expect(f.replyData(Build.message(15, fn, [("functionIR", .data(ir))])) == [1, 0, 0, 0, 0, 0, 0, 0])
        #expect(f.replyData(Build.message(15, fn, [("functionIR", .data(ir))])) == [2, 0, 0, 0, 0, 0, 0, 0])
        // Render pipeline (op 14) on connection 2.
        let payload = MetalKeyedPayloadBuilder.renderPipeline(top: [(1, 2), (2, 1)], label: "quad",
                                                              colorAttachments: [[(0, 0), (1, 80), (2, 1), (4, 5), (7, 5)]])
        let rp = Build.record(14) { $0.u32(0); $0.u32(UInt32(payload.count)); $0.append(payload) }
        #expect(f.replyData(Build.message(12, rp), on: 2) == [1, 0, 0, 0, 0, 0, 0, 0])
        // Compute pipeline (op 11): 24-byte reply, u16 1024, u16 32.
        let cpPayload = MetalKeyedPayloadBuilder.object([(0, 2)])
        let cp = Build.record(11) { $0.u32(0); $0.u32(UInt32(cpPayload.count)); $0.append(cpPayload) }
        let cpReply = f.replyData(Build.message(12, cp), on: 2)
        #expect(cpReply.count == 24 && Build.u32(cpReply, 0) == 1 && Build.u32(cpReply, 2) == 0x0020_0400)
        let calls = f.backend.calls
        guard case let .createFunction(f1, 3000) = calls[0], case let .createFunction(f2, _) = calls[1],
              case let .createRenderPipeline(_, desc) = calls[2], case let .createComputePipeline(_, fcp) = calls[3] else {
            Issue.record("calls \(calls)")
            return
        }
        #expect(desc.label == "quad" && desc.vertexFunction == f1 && desc.fragmentFunction == f2 && fcp == f2)
        #expect(desc.colorAttachments.first?.destinationRGBBlendFactor == 5)
        // Op 37 on connection 0: four u64 from the backend.
        f.backend.limitsValue = MetalLimits(maxThreadsPerThreadgroup: (256, 128, 64), maxThreadgroupMemoryLength: 8192)
        let limits = f.replyData(Build.message(12, Build.record(37) { $0.u32(0) }), on: 0)
        #expect((0..<4).map { Build.u64(limits, $0) } == [256, 128, 64, 8192])
        // Texture views: op 7 and op 27 with a swizzle.
        let tex = Build.record(1) { $0.append(Build.textureWords(usage: 1, format: 80, width: 8, height: 8, levels: 4)) }
        #expect(f.replyData(Build.message(8, tex)) == [1, 0, 0, 0])
        #expect(f.replyData(Build.message(12, Build.record(7) { $0.u32(0); $0.u32(1); $0.u32(81) })) == [2, 0, 0, 0, 0, 0, 0, 0])
        let swz = Build.record(27) { w in
            w.u32(0); w.u32(1); w.u16(80); w.u16(2); w.u64(1); w.u64(2); w.u64(0); w.u64(1); w.u32(0x0203_0405)
        }
        #expect(f.replyData(Build.message(12, swz)) == [3, 0, 0, 0, 0, 0, 0, 0])
        if case let .createTextureView(_, _, v) = f.backend.calls.last {
            #expect(v == MetalTextureViewDescriptor(pixelFormat: 80, textureType: 2, levels: 1..<3, slices: 0..<1, swizzle: [5, 4, 3, 2]))
        } else { Issue.record("no view") }
        // Heaps: op 20, heap buffer 24, size queries 23, 31, 32.
        #expect(f.replyData(Build.message(12, Build.record(20) { $0.u32(0); $0.u64(1 << 20); $0.u16(0x20); $0.u16(0) }))
                == [1, 0, 0, 0, 0, 0, 0, 0])
        #expect(f.replyData(Build.message(12, Build.record(24) { $0.u32(0); $0.u32(1); $0.u64(1000); $0.u64(0); $0.u64(0x20) }))
                == [4, 0, 0, 0, 0, 0, 0, 0])
        let sa = f.replyData(Build.message(12, Build.record(23) { $0.u64(1000); $0.u16(0x20); $0.u16(0) }))
        #expect(Build.u64(sa, 0) == 1000 && Build.u64(sa, 1) == 256)
        let hs = f.replyData(Build.message(12, Build.record(31) { $0.u32(1) }))
        #expect(Build.u64(hs, 0) == 1 << 20 && Build.u64(hs, 2) == 1024)
        let avail = f.replyData(Build.message(12, Build.record(32) { $0.u32(1); $0.u64(4096) }))
        #expect(Build.u64(avail, 0) == (1 << 20) - 4096)
        let tsize = f.replyData(Build.message(12, Build.record(22) {
            $0.append(Build.textureWords(usage: 1, format: 80, width: 256, height: 256, levels: 9))
        }))
        #expect(Build.u64(tsize, 0) >= 349_524 && Build.u64(tsize, 1) == 128)
        // Events: op 28, CPU set (30) and get (41); fences (13); gpuAddress (38).
        #expect(f.replyData(Build.message(12, Build.record(28) { $0.u32(0) })) == [1, 0, 0, 0, 0, 0, 0, 0])
        _ = f.send(Build.message(12, Build.record(30) { $0.u32(1); $0.u64(42) }), on: 0)
        #expect(Build.u64(f.replyData(Build.message(12, Build.record(41) { $0.u32(1) }), on: 0), 0) == 42)
        #expect(f.replyData(Build.message(12, Build.record(13) { $0.u32(0) })) == [1, 0, 0, 0, 0, 0, 0, 0])
        #expect(Build.u64(f.replyData(Build.message(12, Build.record(38) { $0.u32(4) })), 0) >= 0x100_0000_0000)
        #expect(Build.u64(f.replyData(Build.message(12, Build.record(33) { $0.u32(80) })), 0) == 16)
        // An unknown op is refused with an empty reply.
        #expect(f.send(Build.message(12, Build.record(29) { $0.u32(0) }), on: 1).reply == [:])
        #expect(f.core.statistics.refused["12:29"] == 1)
    }

    @Test func replaceRegionAndGetBytes() throws {
        let f = Fixture()
        f.connect()
        let tex = Build.record(1) { $0.append(Build.textureWords(usage: 1, format: 70, width: 3, height: 4)) }
        #expect(f.replyData(Build.message(8, tex)) == [1, 0, 0, 0])
        // §5.3: 3×4 RGBA8, bytes per row 32 → 108 pixel bytes.
        let head = MetalDescriptorCodec.RegionHead(texture: 1, region: MetalRegion(width: 3, height: 4), level: 0, slice: 0,
                                                   bytesPerRow: 32, bytesPerImage: 128)
        let up = Build.record(2) { MetalDescriptorCodec.encodeRegionHead(head, into: &$0); $0.append([UInt8](repeating: 7, count: 108)) }
        #expect(up.count == 8 + 84 + 108)
        #expect(f.send(Build.message(9, up), on: 1).reply == [:])
        // A large upload by memory entry.
        let big = Build.record(2) {
            MetalDescriptorCodec.encodeRegionHead(.init(texture: 1, region: MetalRegion(width: 194, height: 237), level: 0, slice: 0,
                                                        bytesPerRow: 784, bytesPerImage: 0), into: &$0)
            $0.append([UInt8](repeating: 1, count: 236 * 784 + 194 * 4))
        }
        #expect(big.count == 185_892)
        let (entry, _) = f.memory.entry(length: 196_608, bytes: big)
        _ = f.send(Build.message(9, nil, [("command", .largeData(length: UInt32(big.count), port: XPCPort(name: entry, disposition: 17)))]),
                   on: 1)
        // getBytes into a shared region on connection 0.
        let (shm, block) = f.memory.entry(length: 16384)
        let down = Build.record(5) { MetalDescriptorCodec.encodeRegionHead(head, into: &$0); $0.u64(108) }
        f.backend.readBackFill = 0xEE
        #expect(f.send(Build.message(10, down, [("sharedMem", .sharedMemory(size: 16384, port: XPCPort(name: shm, disposition: 17)))]),
                       on: 0).reply == [:])
        let calls = f.backend.calls
        guard calls.count == 4, case let .replaceRegion(h, r, 0, 0, 108, 32) = calls[1],
              case .replaceRegion(h, _, 0, 0, 185_800, 784) = calls[2],
              case .getBytes(h, r, 0, 0, 108, 32) = calls[3] else {
            Issue.record("calls \(calls)")
            return
        }
        #expect(r == MetalRegion(width: 3, height: 4))
        #expect(block.pointer.load(fromByteOffset: 107, as: UInt8.self) == 0xEE)
        #expect(block.pointer.load(fromByteOffset: 108, as: UInt8.self) == 0)
    }

    @Test func iosurfaceTextures() {
        let f = Fixture()
        f.connect()
        let (_, block) = f.memory.entry(length: 1 << 20)
        let region = GuestSharedRegion(pointer: block.pointer, length: block.length, objectID: 77, owner: block)
        f.surfaces.known[0x5005] = IOSurfaceBacking(surfaceID: 9, region: region, width: 64, height: 64, bytesPerRow: 256,
                                                    bytesPerElement: 4, pixelFormat: 0x4247_5241)
        let rec = Build.record(47) { $0.append(Build.textureWords(flags: 1, usage: 5, format: 80, width: 64, height: 64)); $0.u32(0) }
        let o = f.send(Build.message(13, rec, [("iosurface", .sendRight(XPCPort(name: 0x5005, disposition: 17)))]), on: 1)
        #expect(o.reply?["replyData"]?.dataValue == [1, 0, 0, 0, 0, 0, 0, 0] && o.retained == [0x5005])
        guard case let .createTexture(h, _, 9?)? = f.backend.calls.last else { Issue.record("no IOSurface texture"); return }
        // An unknown surface still gets a texture (host memory) and a ref.
        let o2 = f.send(Build.message(13, rec, [("iosurface", .sendRight(XPCPort(name: 0x6006, disposition: 17)))]), on: 1)
        #expect(o2.reply?["replyData"]?.dataValue == [2, 0, 0, 0, 0, 0, 0, 0])
        #expect(f.backend.calls.last.map { if case .createTexture(_, _, nil) = $0 { true } else { false } } == true)
        // Release (1001) drops the surface port.
        _ = f.send(Build.message(14, Build.record(1001) { $0.u32(1) }), on: 1)
        #expect(f.transport.dropped == [0x5005] && f.backend.calls.last == .release(h))
    }

    /// Records a command buffer with render, compute and blit work.
    static func submission(_ cbRef: UInt64, queue: UInt64 = 1) -> XPCDict {
        let render = Build.segment(kind: 0, [
            Build.record(26) { $0.append(Build.renderPass(colors: [(0, 1, 2, 1, [0, 0, 1, 1])], width: 64, height: 64)) },
            Build.record(116) { $0.u32(1) },
            Build.record(1) { $0.u32(3); $0.u16(0); $0.u16(3) },
        ], size: 65536)
        let compute = Build.segment(kind: 1, [Build.record(208) { $0.u32(1) },
                                              Build.record(200) { w in for v in [1, 1, 1, 8, 8, 1] as [UInt64] { w.u64(v) } }])
        let blit = Build.segment(kind: 2, [Build.record(307) { $0.u32(1) }])
        return ["messageType": .uint64(6), "commandQueue": .uint64(queue), "commandBufferRef": .uint64(cbRef),
                "segments": .array([.data(render), .data(compute), .data(blit)])]
    }

    @Test func submissionEventsInOrder() {
        let f = Fixture()
        f.connect(eventPort: 0x777)
        #expect(f.send(["messageType": .uint64(7), "maxCommandBufferCount": .uint64(64)], on: 1).reply?["commandQueueRef"]?.uint64Value == 1)
        let tex = Build.record(1) { $0.append(Build.textureWords(usage: 5, format: 80, width: 64, height: 64)) }
        _ = f.replyData(Build.message(8, tex))
        #expect(f.send(Self.submission(1), on: 0).reply == nil)
        #expect(f.send(Self.submission(2), on: 0).reply == nil)
        f.core.drainEvents()
        #expect(f.transport.summary == [[100, 1, 3], [101, 1, 4], [100, 2, 3], [101, 2, 4]])
        #expect(f.transport.events.allSatisfy { $0.port == 0x777 && $0.event["error"]?.uint64Value == 1
                && $0.event["startTime"]?.doubleValue != nil && $0.event["endTime"]?.doubleValue != nil })
        let cb = f.backend.submitted[0]
        #expect(cb.passes.count == 3 && cb.queue != nil && cb.unknownRecordCount == 0)
        if case let .render(p) = cb.passes[0] { #expect(p.commands.count == 2) } else { Issue.record("render") }
        if case .compute = cb.passes[1] {} else { Issue.record("compute") }
        if case .blit = cb.passes[2] {} else { Issue.record("blit") }
        #expect(f.core.statistics.submissions == 2 && f.core.statistics.completedEvents == 2)
    }

    @Test func eventOrderWhenTheBackendReportsLateOrNever() {
        let f = Fixture(completesImmediately: false)
        f.connect()
        _ = f.send(["messageType": .uint64(7), "maxCommandBufferCount": .uint64(64)], on: 1)
        for cb in 1...4 as ClosedRange<UInt64> { _ = f.send(Self.submission(cb), on: 0) }
        f.core.drainEvents()
        #expect(f.transport.events.isEmpty)  // nothing before the backend says so (§9)
        // 1: completed without a scheduled report → 100 then 101.
        f.backend.completeNext(reportScheduled: false)
        // 2: scheduled reported, completed with an error status.
        f.backend.completeNext(status: 5)
        // 3: scheduled only (the frame's surface writes are done), 101 later.
        let p = f.backend.pending
        p[0].scheduled()
        f.core.drainEvents()
        #expect(f.transport.summary == [[100, 1, 3], [101, 1, 4], [100, 2, 3], [101, 2, 5], [100, 3, 3]])
        p[0].completed(4)
        p[0].scheduled()  // a late or repeated report changes nothing
        p[0].completed(4)
        f.core.drainEvents()
        #expect(f.transport.summary.suffix(1) == [[101, 3, 4]] && f.transport.events.count == 6)
    }

    @Test func processEndReleasesEverything() {
        let f = Fixture()
        f.connect()
        let (shm, _) = f.memory.entry(length: 16384)
        _ = f.send(["messageType": .uint64(1), "length": .uint64(64), "options": .uint64(0),
                    "sharedMem": .sharedMemory(size: 16384, port: XPCPort(name: shm, disposition: 17))], on: 1)
        _ = f.send(Build.message(15, Build.record(15) { $0.u32(0); $0.u32(0); $0.u32(0) }, [("functionIR", .data([1, 2, 3]))]), on: 1)
        _ = f.send(["messageType": .uint64(7), "maxCommandBufferCount": .uint64(64)], on: 1)
        #expect(f.core.statistics.liveObjects == 3)
        for c in 0x100...0x102 as ClosedRange<UInt32> { f.core.connectionClosed(c) }
        let releases = f.backend.calls.filter { if case .release = $0 { true } else { false } }
        #expect(releases.count == 2 && f.transport.dropped == [shm] && f.core.statistics.liveObjects == 0)
    }

    @Test func malformedMessagesGetEmptyReplies() {
        let f = Fixture()
        f.connect()
        #expect(f.send(Build.message(8, [1, 2, 3]), on: 1).reply == [:])
        #expect(f.send(Build.message(8, Build.record(1) { $0.u32(0) }), on: 1).reply == [:])
        #expect(f.send(Build.message(99), on: 1).reply == [:])
        #expect(f.send(Build.message(14, Build.record(1004) { $0.u32(1) }), on: 1).reply == nil)
        #expect(f.send(Build.message(14, Build.record(1000) { $0.u32(55) }), on: 1).reply == nil)
        #expect(f.send(["messageType": .uint64(6), "commandBufferRef": .uint64(1), "segments": .array([.data([1])])], on: 0).reply == nil)
        f.core.drainEvents()
        #expect(f.transport.summary == [[100, 1, 3], [101, 1, 4]])
        #expect(f.core.statistics.refused["8:1"] == 1 && f.core.statistics.refused["99"] == 1)
    }
}
