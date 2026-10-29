import Foundation
import Testing
@testable import YcodeMetalHost
import YcodeXPC

/// The service logic (spec §2–§9) driven with synthetic messages.
@Suite struct CoreTests {
    final class Fixture: @unchecked Sendable {
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

        func replyData(_ d: XPCDict, on type: UInt32 = 1, base: UInt32 = 0x100) -> [UInt8] {
            send(d, on: type, base: base).reply?["replyData"]?.dataValue ?? []
        }
    }

    /// messageTypes 17 and 18 (visionos.md §10.6.5): a shared event's
    /// handle is a host port; opening it in another process gives a new ref
    /// naming the same event; the port lives while any ref does.
    @Test func sharedEventHandlesNameOneEventAcrossProcesses() {
        let f = Fixture()
        f.connect()
        f.connect(base: 0x300, eventPort: 0x400)
        // Process A: a shared event (op 28), value 7 (op 30).
        #expect(f.replyData(Build.message(12, Build.record(28) { $0.u32(0) })) == [1, 0, 0, 0, 0, 0, 0, 0])
        _ = f.send(Build.message(12, Build.record(30) { $0.u32(1); $0.u64(7) }), on: 0)
        // 17: a send right (MAKE_SEND) and labelTraceID 0; the same port twice.
        let h1 = f.send(["messageType": .uint64(17), "eventRef": .uint64(1)], on: 1).reply ?? [:]
        guard case let .sendRight(port)? = h1["eventPort"] else {
            Issue.record("no eventPort in \(h1)")
            return
        }
        #expect(port.disposition == XPCDisposition.makeSend && h1["labelTraceID"]?.uint64Value == 0)
        let h2 = f.send(["messageType": .uint64(17), "eventRef": .uint64(1)], on: 1).reply ?? [:]
        #expect(h2["eventPort"]?.port?.name == port.name)
        // 18 in process B: a new ref, a backend alias of A's event.
        let open = Build.message(18, Build.record(40) { $0.u32(0) }, [("eventPort", .sendRight(XPCPort(name: port.name, disposition: 17)))])
        #expect(f.send(open, on: 1, base: 0x300).reply?["replyData"]?.dataValue == [1, 0, 0, 0, 0, 0, 0, 0])
        let calls = f.backend.calls
        guard case let .createEvent(ha) = calls.first(where: { if case .createEvent = $0 { true } else { false } }),
              case let .createEventAlias(hb, of: orig)? = calls.last else {
            Issue.record("calls \(calls)")
            return
        }
        #expect(orig == ha && hb != ha)
        // A value set through one ref is read through the other.
        let v = f.replyData(Build.message(12, Build.record(41) { $0.u32(1) }), on: 0, base: 0x300)
        #expect(Build.u64(v, 0) == 7)
        _ = f.send(Build.message(12, Build.record(30) { $0.u32(1); $0.u64(9) }), on: 0, base: 0x300)
        #expect(Build.u64(f.replyData(Build.message(12, Build.record(41) { $0.u32(1) }), on: 0), 0) == 9)
        // Releasing A's ref keeps the port; releasing B's destroys it.
        _ = f.send(Build.message(14, Build.record(1013) { $0.u32(1) }), on: 1)
        #expect(f.transport.destroyedEventPorts.isEmpty)
        _ = f.send(Build.message(14, Build.record(1013) { $0.u32(1) }), on: 1, base: 0x300)
        #expect(f.transport.destroyedEventPorts == [port.name])
        // 18 with a port that names nothing: a fresh event, counted as refused.
        #expect(f.send(open, on: 1, base: 0x300).reply?["replyData"]?.dataValue == [1, 0, 0, 0, 0, 0, 0, 0])
        if case .createEvent = f.backend.calls.last {} else { Issue.record("no fresh event: \(f.backend.calls.last as Any)") }
        #expect(f.core.statistics.refused["18"] == 1)
        // 17 of an unknown ref: no port.
        #expect(f.send(["messageType": .uint64(17), "eventRef": .uint64(9)], on: 1).reply?["eventPort"] == nil)
        // 18 with eventPort MACH_PORT_NULL (`newSharedEventWithHandle:nil`,
        // visionos.md §10.12.2): an empty dictionary, no event, not refused.
        let callCount = f.backend.calls.count
        let null = Build.message(18, Build.record(40) { $0.u32(0) }, [("eventPort", .sendRight(XPCPort(name: 0, disposition: 17)))])
        #expect(f.send(null, on: 1, base: 0x300).reply == [:])
        #expect(f.send(Build.message(18, Build.record(40) { $0.u32(0) }), on: 1, base: 0x300).reply == [:])
        #expect(f.backend.calls.count == callCount && f.core.statistics.refused["18"] == 1 && f.core.nullEventOpenings == 2)
    }

    /// A process that ends with an exported event gives its port back once
    /// no ref remains.
    @Test func exportedEventPortEndsWithTheLastRef() {
        let f = Fixture()
        f.connect()
        _ = f.replyData(Build.message(12, Build.record(28) { $0.u32(0) }))
        let port = f.send(["messageType": .uint64(17), "eventRef": .uint64(1)], on: 1).reply?["eventPort"]?.port?.name ?? 0
        #expect(port != 0)
        #expect(f.core.snapshotBusyReason != nil, "an exported handle blocks snapshots")
        for t in 0..<3 as Range<UInt32> { f.core.connectionClosed(0x100 + t) }
        #expect(f.transport.destroyedEventPorts == [port])
        #expect(f.core.snapshotBusyReason == nil)
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
        let payload = MetalKeyedPayloadBuilder.renderPipeline(top: [(1, 1), (2, 2)], label: "quad",
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
        // Op 37 on connection 0: four u64 from the backend, z at least 512
        // (the guest driver keeps its own cap of 512, visionos.md §10.6.1).
        f.backend.limitsValue = MetalLimits(maxThreadsPerThreadgroup: (256, 128, 64), maxThreadgroupMemoryLength: 8192)
        let limits = f.replyData(Build.message(12, Build.record(37) { $0.u32(0) }), on: 0)
        #expect((0..<4).map { Build.u64(limits, $0) } == [256, 128, 512, 8192])
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
        // The wire form of ops 21 and 22: descriptor words 1–8 without word 0
        // (a 1×1 RGBA8 2D texture as RealityKit asks for it; visionos.md §10).
        let words18 = Array(Build.textureWords(usage: 0, format: 70, width: 1, height: 1, levels: 1).dropFirst(4))
        #expect(words18.count == 32)
        let tsize32 = f.replyData(Build.message(12, Build.record(22) { $0.append(words18) }))
        #expect(Build.u64(tsize32, 0) >= 4 && Build.u64(tsize32, 1) == 128)
        let heapTexture = f.replyData(Build.message(12, Build.record(21) {
            $0.u32(0); $0.u32(1); $0.append(words18); $0.pad(to: 52)
        }))
        #expect(heapTexture.count == 8 && Build.u32(heapTexture, 0) != 0)
        #expect(f.core.statistics.refused["12:22"] == nil)
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

    /// Op 19 (visionos.md §10.20.7): a set call of kind 0 names the argument
    /// buffer and offset; a buffer member (kind 1) is written there as the
    /// buffer's GPU address plus the call's offset, at the member index × 8.
    @Test func argumentEncoderSetCallsWriteTheirMembers() {
        let f = Fixture()
        f.connect()
        _ = f.replyData(Build.message(12, Build.record(20) { $0.u32(0); $0.u64(1 << 20); $0.u16(0x20); $0.u16(0) }))
        func heapBuffer() -> UInt32 {
            Build.u32(f.replyData(Build.message(12, Build.record(24) { $0.u32(0); $0.u32(1); $0.u64(4096); $0.u64(0); $0.u64(0x20) })), 0)
        }
        let argumentBuffer = heapBuffer(), data = heapBuffer()
        let address = Build.u64(f.replyData(Build.message(12, Build.record(38) { $0.u32(data) })), 0)
        let layout = Build.u32(f.replyData(Build.message(12, Build.record(16) { $0.u32(0) })), 0)
        let encoder = Build.u32(f.replyData(Build.message(12, Build.record(17) { $0.u32(0); $0.u32(layout) })), 0)
        func set(kind: UInt8, index: UInt8, object: UInt32, offset: UInt64) {
            _ = f.send(Build.message(12, Build.record(19) {
                $0.u32(encoder); $0.u8(kind); $0.u8(index); $0.u16(0)
                $0.u32(0); $0.u32(0x100); $0.u32(0); $0.u32(0)
                $0.u32(object); $0.u64(offset)
            }), on: 1)
        }
        set(kind: 0, index: 0, object: argumentBuffer, offset: 256)
        set(kind: 1, index: 3, object: data, offset: 16)
        set(kind: 1, index: 4, object: 0, offset: 0)
        let writes = f.backend.calls.compactMap { c -> (Int, [UInt8])? in
            if case let .writeBuffer(_, offset, bytes) = c { return (offset, bytes) }
            return nil
        }
        var expected = MetalByteWriter()
        expected.u64(address + 16)
        #expect(writes.count == 2)
        #expect(writes.first.map { $0.0 == 256 + 24 && $0.1 == expected.bytes } == true, "\(writes)")
        #expect(writes.last.map { $0.0 == 256 + 32 && $0.1 == [UInt8](repeating: 0, count: 8) } == true, "\(writes)")
        #expect(f.core.statistics.refused["12:19"] == nil)
    }

    /// Op 22 follows the rule fitted to the reference's answers and op 20
    /// grants heaps in 16 KiB units (visionos.md §10.8.3).
    @Test func heapSizesFollowTheReferenceRule() {
        func answer(_ format: UInt32, _ w: Int, _ h: Int = 1, type: UInt8 = MetalTextureType.type2D, depth: Int = 1,
                    levels: Int = 1, array: Int = 1, usage: UInt16) -> (UInt64, UInt64) {
            let d = MetalTextureDescriptor(textureType: type, pixelFormat: format, width: w, height: h, depth: depth,
                                           mipmapLevelCount: levels, arrayLength: array, usage: usage)
            let a = MetalHostCore.heapTextureSizeAndAlign(d)
            return (a.size, a.align)
        }
        let read = MetalTextureUsage.shaderRead, write = MetalTextureUsage.shaderWrite, rt: UInt16 = 4
        // The texture manager's 29 answers (RGBA8Unorm 70, RGBA16Float 115, RGBA8Uint 73, R8Uint 13, BGRA8Unorm 80).
        #expect(answer(70, 1, 1, usage: 0) == (128, 128))
        #expect(answer(115, 1, 1, type: MetalTextureType.typeCube, usage: read) == (768, 128))
        #expect(answer(70, 1, 1, type: MetalTextureType.type3D, depth: 1, usage: read) == (128, 128))
        #expect(answer(70, 64, 64, levels: 7, usage: read) == (22_528, 128))
        #expect(answer(70, 1, type: MetalTextureType.typeTextureBuffer, usage: read) == (4, 16))
        #expect(answer(70, 1, type: MetalTextureType.type1D, usage: read) == (128, 128))
        #expect(answer(70, 1, type: MetalTextureType.type1DArray, array: 1, usage: read) == (128, 128))
        #expect(answer(70, 1, 1, usage: read | write) == (128, 128))
        #expect(answer(13, 1024, 1024, usage: read | rt) == (1_081_344, 128))
        #expect(answer(80, 4096, 4096, usage: read | rt) == (67_633_152, 128))
        // Further examples of the rule.
        #expect(answer(70, 4096, 4096, usage: 0).0 == 67_108_864)
        #expect(answer(70, 4096, 4096, usage: write).0 == 67_108_864)
        #expect(answer(70, 1920, 1080, usage: 0).0 == 8_355_840)
        #expect(answer(70, 1920, 1080, usage: read).0 == 8_486_912)
        #expect(answer(115, 3840, 2160, usage: rt).0 == 67_371_008)
        #expect(answer(70, 1000, 1000, usage: read).0 == 4_227_072)
        // The engine's two heaps as the reference grants them.
        #expect(MetalHostCore.grantedHeapSize(28_032) == 32_768)
        #expect(MetalHostCore.grantedHeapSize(67_633_280) == 67_649_536)
        #expect(MetalHostCore.grantedHeapSize(1) == 16_384)
        #expect(MetalHostCore.grantedHeapSize(1 << 20) == 1 << 20)
        let f = Fixture()
        f.connect()
        _ = f.replyData(Build.message(12, Build.record(20) { $0.u32(0); $0.u64(28_032); $0.u16(0x20); $0.u16(0) }))
        let hs = f.replyData(Build.message(12, Build.record(31) { $0.u32(1) }))
        #expect(Build.u64(hs, 0) == 32_768 && Build.u64(hs, 1) == 32_768 && Build.u64(hs, 2) == 0)
    }

    /// wakeboardd's request: 2D array, BGRA8Unorm_sRGB 3840 × 2160, ShaderRead | RenderTarget, private.
    static let wakeboarddLayer: [UInt8] = [
        0x00, 0x00, 0x00, 0x00, 0x43, 0x05, 0x51, 0x00, 0x00, 0x0F, 0x00, 0x00, 0x70, 0x08, 0x00, 0x00,
        0x01, 0x00, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x01, 0x00, 0x20, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00]

    /// messageType 19 (a shared texture, metal-sim-protocol.md §5.10): op 42
    /// carries the descriptor; the host makes a surface whose creation
    /// properties describe the texture (`kMetalRegistryID` = the hand-shake
    /// `registryID`), allocation = op 22's size + 16, and replies with
    /// exactly its port and the texture's ref.
    @Test func sharedTextureGetsAHostSurface() {
        let f = Fixture()
        f.connect()
        let reply = f.send(Build.message(19, Build.record(42) { $0.append(Self.wakeboarddLayer) }), on: 1).reply ?? [:]
        #expect(Set(reply.keys) == ["iosurfaceXPCObject", "replyData"])
        #expect(f.surfaces.made.count == 1)
        if let m = f.surfaces.made.first {
            let n = Dictionary(m.properties.map { ($0.key, $0.value) }, uniquingKeysWith: { a, _ in a })
            #expect(m.allocation == 33_947_664 && m.name == "Metal" && n["IOSurfaceAllocSize"] == 33_947_664)
            #expect(n["kMetalRegistryID"] == f.core.registryID && n["MetalSharedTexture"] == nil)
            #expect(n["kMetalTextureType"] == 3 && n["kMetalTexturePixelFormat"] == 81 && n["kMetalTextureWidth"] == 3840
                    && n["kMetalTextureHeight"] == 2160 && n["kMetalTextureDepth"] == 1 && n["kMetalTextureArrayLength"] == 1
                    && n["kMetalTextureMipmapLevelCount"] == 1 && n["kMetalTextureSampleCount"] == 1)
            #expect(n["kMetalTextureUsage"] == 5 && n["kMetalTextureResourceOptions"] == 32 && n["kMetalTextureGPUOptimization"] == 1
                    && n["kMetalTextureSwizzleKey"] == 0x0504_0302 && n["kMetalTextureRotation"] == 0
                    && n["IOSurfacePixelSizeCastingAllowed"] == 1 && n["kAGXCompressionMode"] == 0)
        }
        if case let .sendRight(port)? = reply["iosurfaceXPCObject"] {
            #expect(port.name == 0x9001 && port.disposition == XPCDisposition.makeSend)
        } else {
            Issue.record("no iosurfaceXPCObject")
        }
        let data = reply["replyData"]?.dataValue ?? []
        #expect(data.count == 8 && Build.u32(data, 0) != 0 && Build.u32(data, 1) == 0)
        #expect(f.core.statistics.refused["19"] == nil)
        if case let .createTexture(_, desc, iosurface)? = f.backend.calls.last {
            #expect(desc.textureType == MetalTextureType.type2DArray && desc.pixelFormat == 81 && desc.width == 3840 && iosurface == nil)
        } else {
            Issue.record("no texture")
        }
        // 64 × 64 BGRA8 ShaderRead → 16 528; 1 × 1 → 144 (visionos.md §10.10.2).
        _ = f.send(Build.message(19, Build.record(42) { $0.append(Build.textureWords(usage: 1, format: 80, width: 64, height: 64)) }), on: 1)
        _ = f.send(Build.message(19, Build.record(42) { $0.append(Build.textureWords(usage: 1, format: 80, width: 1, height: 1)) }), on: 1)
        #expect(f.surfaces.made.map(\.allocation) == [33_947_664, 16_528, 144])
    }

    /// messageType 20 (metal-sim-protocol.md §5.11): opening a handle, in the
    /// creating process and in a second one, gives a new ref over the same
    /// GPU image and replies with the ref and descriptor words 1–8 (hazard
    /// tracking "tracked"); the label is logged; a surface without `kMetal…`
    /// properties, or an unknown port, gets an empty reply.
    @Test func sharedTextureHandleOpensTheSameImage() {
        let f = Fixture()
        f.connect()
        f.connect(base: 0x300, eventPort: 0x400)
        let made = f.send(Build.message(19, Build.record(42) { $0.append(Self.wakeboarddLayer) }), on: 1).reply ?? [:]
        guard let surfacePort = made["iosurfaceXPCObject"]?.port?.name else { Issue.record("no surface"); return }
        guard case let .createTexture(original, _, _)? = f.backend.calls.last else { Issue.record("no texture"); return }
        func open(_ base: UInt32, label: String?) -> XPCDict {
            var d = Build.message(20, Build.record(43) { $0.u32(0) })
            d["iosurface"] = .sendRight(XPCPort(name: surfacePort, disposition: 17))
            if let label { d["label"] = .string(label) }
            return f.send(d, on: 1, base: base).reply ?? [:]
        }
        let label = "wakeboardd-layer 2 [frame 1/3 protection:0 size:3840x2160 recorder:False]: Color (Layered)"
        let r = open(0x300, label: label)
        #expect(Set(r.keys) == ["replyData"])
        let data = r["replyData"]?.dataValue ?? []
        #expect(data.count == 36)
        // Process B's first resource ref; words 1–8 as message 19's, options 0x0220.
        #expect(Build.u32(data, 0) == 1 && Build.u32(data, 1) == 0x0051_0543 && Build.u32(data, 2) == 3840
                && Build.u32(data, 3) == 2160 && Build.u32(data, 4) == 1 && Build.u32(data, 5) == 0x0001_0001
                && Build.u32(data, 6) == 0x0220_0001 && Build.u32(data, 7) == 0 && Build.u32(data, 8) == 0)
        if case let .createTextureView(_, parent, view)? = f.backend.calls.last {
            #expect(parent == original && view.levels == nil && view.slices == nil)
        } else {
            Issue.record("no alias of the shared texture: \(f.backend.calls.last.map { "\($0)" } ?? "none")")
        }
        #expect(f.logs.contains { $0.contains("shared texture opened") && $0.contains(label) })
        // The same process opens its own handle: a second ref there.
        let own = open(0x100, label: nil)
        #expect(Build.u32(own["replyData"]?.dataValue ?? [], 0) == 2)
        // Release the creator's texture: the handle in B still names the image, and
        // a later opening aliases B's.
        _ = f.send(Build.message(14, Build.record(1000) { $0.u32(1) }), on: 1)
        _ = f.send(Build.message(14, Build.record(1000) { $0.u32(2) }), on: 1)
        _ = open(0x100, label: nil)
        if case let .createTextureView(_, parent, _)? = f.backend.calls.last {
            #expect(parent != original)
        } else {
            Issue.record("no alias after the release")
        }
        // Snapshots wait while opened handles exist.
        #expect(f.core.snapshotBusyReason?.contains("shared-texture") == true)
        // A surface with only kMetalRegistryID, and an unknown port: empty replies.
        f.surfaces.described[0x9100] = MetalSurfaceDescription(id: 77, numbers: ["kMetalRegistryID": f.core.registryID])
        var d = Build.message(20, Build.record(43) { $0.u32(0) })
        d["iosurface"] = .sendRight(XPCPort(name: 0x9100, disposition: 17))
        #expect(f.send(d, on: 1).reply == [:])
        d["iosurface"] = .sendRight(XPCPort(name: 0x9200, disposition: 17))
        #expect(f.send(d, on: 1).reply == [:])
    }

    /// messageType 20 for a surface a guest made with the `kMetal…`
    /// properties: a texture over the surface's memory, with the descriptor
    /// the properties give (64 × 64 BGRA8Unorm 2D: word 1 0x00500542).
    @Test func sharedTextureHandleOfAGuestSurface() {
        let f = Fixture()
        f.connect()
        f.surfaces.described[0x9100] = MetalSurfaceDescription(id: 5, numbers: [
            "kMetalRegistryID": f.core.registryID, "kMetalTextureType": 2, "kMetalTexturePixelFormat": 80,
            "kMetalTextureWidth": 64, "kMetalTextureHeight": 64, "kMetalTextureUsage": 5, "kMetalTextureGPUOptimization": 1,
        ])
        var d = Build.message(20, Build.record(43) { $0.u32(0) })
        d["iosurface"] = .sendRight(XPCPort(name: 0x9100, disposition: 17))
        let outcome = f.send(d, on: 1)
        let data = outcome.reply?["replyData"]?.dataValue ?? []
        #expect(data.count == 36 && Build.u32(data, 1) == 0x0050_0542 && Build.u32(data, 2) == 64 && Build.u32(data, 6) == 0x0200_0001)
        #expect(outcome.retained == [0x9100])
        if case let .createTexture(_, desc, _)? = f.backend.calls.last {
            #expect(desc.width == 64 && desc.pixelFormat == 80 && desc.textureType == 2)
        } else {
            Issue.record("no texture")
        }
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

    /// Diagnostics: the hand-shake sender's guest pid, the per-process
    /// summary, and one log line per unmodelled pipeline key.
    @Test func diagnosticsSummaryAndUnknownPipelineKeys() {
        let f = Fixture()
        for type in 0..<3 as Range<UInt32> {
            f.core.connectionOpened(0x100 + type, clientPort: 0x200 + type)
            _ = f.core.handle(["messageType": .uint64(0), "connectionType": .uint64(UInt64(type)), "processRef": .uint64(type == 0 ? 0 : 1)],
                              connection: 0x100 + type, senderPID: 124)
        }
        _ = f.send(["messageType": .uint64(7), "maxCommandBufferCount": .uint64(64)], on: 1)
        _ = f.send(Self.submission(1), on: 0)
        f.core.drainEvents()
        let lines = f.core.processSummary()
        #expect(lines.count == 1)
        #expect(lines.first?.contains("guest pid 124") == true && lines.first?.contains("1 submitted") == true
                && lines.first?.contains("1 completed") == true && lines.first?.contains("0 outstanding") == true)
        // A render pipeline with keys 6 and 7 (not modelled) logs each key once.
        let payload = MetalKeyedPayloadBuilder.renderPipeline(top: [(1, 1), (6, 3), (7, 9)])
        let rp = Build.record(14) { $0.u32(0); $0.u32(UInt32(payload.count)); $0.append(payload) }
        _ = f.replyData(Build.message(12, rp), on: 2)
        _ = f.replyData(Build.message(12, rp), on: 2)
        let notes = f.logLock.withLock { f.logs.filter { $0.contains("descriptor key") } }
        #expect(notes.count == 2 && notes[0].contains("key 6") && notes[1].contains("key 7"))
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

    @Test func completionsRacingWithProcessEnd() {
        // Completions arrive on many threads while the process ends: events
        // read the process state under the lock, and none go out after the end.
        let f = Fixture(completesImmediately: false)
        f.connect(eventPort: 0x777)
        _ = f.send(["messageType": .uint64(7), "maxCommandBufferCount": .uint64(64)], on: 1)
        for cb in 1...64 as ClosedRange<UInt64> { _ = f.send(Self.submission(cb), on: 0) }
        let pending = f.backend.pending
        DispatchQueue.concurrentPerform(iterations: pending.count + 1) { i in
            if i == pending.count {
                for c in 0x100...0x102 as ClosedRange<UInt32> { f.core.connectionClosed(c) }
            } else {
                pending[i].scheduled()
                pending[i].completed(4)
            }
        }
        for p in pending { p.completed(4) }  // after the end: nothing more is sent
        let sent = f.transport.events.count
        usleep(50_000)
        #expect(f.transport.events.count == sent && f.transport.events.allSatisfy { $0.port == 0x777 })
        // Each command buffer that got events got 100 before 101.
        var seen: [UInt64: [UInt64]] = [:]
        for e in f.transport.summary { seen[e[1], default: []].append(e[0]) }
        #expect(seen.values.allSatisfy { $0 == [100, 101] || $0 == [100] })
        #expect(f.core.statistics.processes == 0)
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

/// Objects whose backend create call is still running when the process
/// ends must be released once the call returns (no leaked GPU objects).
@Suite struct CreateAfterEndTests {
    /// Forwards to a NullBackend; `createBuffer` and `createFunction` wait at a gate.
    final class GatedBackend: MetalBackend, @unchecked Sendable {
        let inner = NullBackend()
        let entered = DispatchSemaphore(value: 0)
        let gate = DispatchSemaphore(value: 0)
        var isAvailable: Bool { false }
        func limits() -> MetalLimits { inner.limits() }
        func createBuffer(_ h: MetalHandle, length: Int, storage: MetalStorageMode, guestMemory: GuestSharedRegion?) throws {
            entered.signal(); gate.wait()
            try inner.createBuffer(h, length: length, storage: storage, guestMemory: guestMemory)
        }
        func createTexture(_ h: MetalHandle, _ d: MetalTextureDescriptor, iosurface: IOSurfaceBacking?) throws {
            try inner.createTexture(h, d, iosurface: iosurface)
        }
        func createTextureView(_ h: MetalHandle, parent: MetalHandle, _ d: MetalTextureViewDescriptor) throws {
            try inner.createTextureView(h, parent: parent, d)
        }
        func createSampler(_ h: MetalHandle, _ d: MetalSamplerDescriptor) throws { try inner.createSampler(h, d) }
        func createDepthStencilState(_ h: MetalHandle, _ d: MetalDepthStencilDescriptor) throws { try inner.createDepthStencilState(h, d) }
        func createFunction(_ h: MetalHandle, metallib: [UInt8]) throws {
            entered.signal(); gate.wait()
            try inner.createFunction(h, metallib: metallib)
        }
        func createRenderPipeline(_ h: MetalHandle, _ d: MetalRenderPipelineDescriptor) throws { try inner.createRenderPipeline(h, d) }
        func createComputePipeline(_ h: MetalHandle, function: MetalHandle) throws -> MetalComputePipelineInfo {
            try inner.createComputePipeline(h, function: function)
        }
        func replaceRegion(texture: MetalHandle, _ r: MetalRegion, level: Int, slice: Int, bytes: [UInt8], bytesPerRow: Int,
                           bytesPerImage: Int) throws {}
        func getBytes(texture: MetalHandle, _ r: MetalRegion, level: Int, slice: Int, into: GuestSharedRegion, bytesPerRow: Int,
                      bytesPerImage: Int) throws {}
        func release(_ h: MetalHandle) { inner.release(h) }
        func submit(_ cb: MetalCommandBuffer, scheduled: @escaping @Sendable () -> Void, completed: @escaping @Sendable (Int) -> Void) {
            inner.submit(cb, scheduled: scheduled, completed: completed)
        }
    }

    @Test func objectsCreatedWhileTheProcessEndsAreReleased() {
        let backend = GatedBackend()
        let memory = FakeMemory(), transport = FakeTransport()
        let core = MetalHostCore(backend: backend, memory: memory, surfaces: nil, log: { _ in })
        core.transport = transport
        var processRef: UInt64 = 0
        for type in 0..<3 as Range<UInt32> {
            core.connectionOpened(0x100 + type, clientPort: 0x200)
            let r = core.handle(["messageType": .uint64(0), "connectionType": .uint64(UInt64(type)), "processRef": .uint64(processRef)],
                                connection: 0x100 + type).reply!
            processRef = r["processRef"]!.uint64Value!
        }
        // A finished object, then a shared buffer and a function whose creates are stalled.
        _ = core.handle(Build.message(8, Build.record(3) { $0.append(MetalDescriptorCodec.encodeSampler(MetalSamplerDescriptor())) }),
                        connection: 0x101)
        let (shm, _) = memory.entry(length: 16384)
        let done = DispatchGroup()
        DispatchQueue.global().async(group: done) {
            _ = core.handle(["messageType": .uint64(1), "length": .uint64(64), "options": .uint64(0),
                             "sharedMem": .sharedMemory(size: 16384, port: XPCPort(name: shm, disposition: 17))], connection: 0x101)
        }
        backend.entered.wait()
        DispatchQueue.global().async(group: done) {
            _ = core.handle(Build.message(15, Build.record(15) { $0.u32(0); $0.u32(0); $0.u32(0) }, [("functionIR", .data([1]))]),
                            connection: 0x102)
        }
        backend.entered.wait()
        // The process ends while both creates are in the backend.
        for c in 0x100...0x102 as ClosedRange<UInt32> { core.connectionClosed(c) }
        let releasedAtEnd = backend.inner.calls.filter { if case .release = $0 { true } else { false } }.count
        #expect(releasedAtEnd == 1)  // only the sampler: the others are not created yet
        backend.gate.signal(); backend.gate.signal()
        done.wait()
        let calls = backend.inner.calls
        var created: Set<MetalHandle> = [], released: Set<MetalHandle> = []
        for c in calls {
            switch c {
            case let .createBuffer(h, _, _, _), let .createFunction(h, _), let .createSampler(h, _): created.insert(h)
            case let .release(h): released.insert(h)
            default: break
            }
        }
        #expect(created.count == 3 && created == released)
        #expect(transport.dropped == [shm])
        #expect(core.statistics.processes == 0 && core.statistics.liveObjects == 0)
    }
}
