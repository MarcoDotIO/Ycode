import Foundation
import Testing
@testable import YcodeMetalHost
import YcodeDarwinKernel
import YcodeXPC

/// Argument buffers (metal-sim-protocol.md §4.3): op 16's layout
/// description parsed into an index → offset table, op 17's reply
/// (alignment, then length), op 19's set calls (24-bit index, count, range
/// forms) written at the table's offsets, op 35's member offsets, and the
/// 8 × index rule only for encoders without a description. The descriptions
/// are built from the spec's grammar (no captured bytes).
@Suite struct ArgumentLayoutTests {
    typealias B = MetalArgumentLayoutBuilder
    typealias Fixture = CoreTests.Fixture

    static func offsets(_ l: MetalArgumentLayout) -> [UInt32: Int] { l.members.mapValues(\.offset) }

    /// The spec's example (§4.3.2): ids 200, 201, 230, 231 sit at 0, 8, 16, 24; length 32, alignment 8.
    static let sparse: [B.Member] = [
        B.Member("a", offset: 0, index: 200, .argument(.buffer())),
        B.Member("b", offset: 8, index: 201, .argument(.buffer(kind: 1))),
        B.Member("t", offset: 16, index: 230, .argument(.texture())),
        B.Member("s", offset: 24, index: 231, .argument(.sampler())),
    ]

    @Test func sparseIdsTakeTheDescriptionsOffsets() throws {
        let l = try MetalArgumentLayout.parse(recordBody: B.recordBody(Self.sparse))
        #expect(Self.offsets(l) == [200: 0, 201: 8, 230: 16, 231: 24])
        #expect(l.encodedLength == 32 && l.alignment == 8)
        #expect(l.member(230)?.kind == .texture && l.member(231)?.kind == .sampler && l.member(201)?.kind == .constantBuffer)
        #expect(!l.isDense)
        // Payload alone parses the same.
        #expect(try MetalArgumentLayout.parse(payload: B.payload(Self.sparse)) == l)
    }

    @Test func inlineDataSetsLengthAndAlignment() throws {
        // float (3), buffer (10), float4 (11), sampler (40): 0, 8, 16, 32; length 48, alignment 16.
        let l = try MetalArgumentLayout.parse(payload: B.payload([
            B.Member("f", offset: 0, index: 3, .argument(.inline(dataType: 3, size: 4, alignment: 4))),
            B.Member("b", offset: 8, index: 10, .argument(.buffer())),
            B.Member("v", offset: 16, index: 11, .argument(.inline(dataType: 6, size: 16, alignment: 16))),
            B.Member("s", offset: 32, index: 40, .argument(.sampler())),
        ]))
        #expect(Self.offsets(l) == [3: 0, 10: 8, 11: 16, 40: 32])
        #expect(l.encodedLength == 48 && l.alignment == 16)
        #expect(l.member(11).map { $0.kind == .inlineData && $0.size == 16 } == true)
        // One float: 4, 4. half (3), char (4): 0, 2; 4, 2.
        let one = try MetalArgumentLayout.parse(payload: B.payload([B.Member(offset: 0, index: 0, .argument(.inline(dataType: 3, size: 4, alignment: 4)))]))
        #expect(one.encodedLength == 4 && one.alignment == 4)
        let small = try MetalArgumentLayout.parse(payload: B.payload([
            B.Member(offset: 0, index: 3, .argument(.inline(dataType: 16, size: 2, alignment: 2))),
            B.Member(offset: 2, index: 4, .argument(.inline(dataType: 45, size: 1, alignment: 1))),
        ]))
        #expect(Self.offsets(small) == [3: 0, 4: 2] && small.encodedLength == 4 && small.alignment == 2)
        // 15 buffers (visionOS RealityKit's shape): 0, 8, …, 112; 120, 8; dense.
        let fifteen = try MetalArgumentLayout.parse(payload: B.payload((0..<15).map {
            B.Member(offset: 8 * $0, index: $0, .argument(.buffer(kind: 2)))
        }))
        #expect(fifteen.encodedLength == 120 && fifteen.alignment == 8 && fifteen.isDense && fifteen.members.count == 15)
    }

    @Test func nestedStructsAddOffsetsAndIndices() throws {
        // struct In { buffer; texture; float; } at ids 0 and 10: 0–2 at 0, 8, 16; 10–12 at 24, 32, 40.
        let inner: [B.Member] = [
            B.Member("b", offset: 0, index: 0, .argument(.buffer())),
            B.Member("t", offset: 8, index: 1, .argument(.texture())),
            B.Member("f", offset: 16, index: 2, .argument(.inline(dataType: 3, size: 4, alignment: 4))),
        ]
        let l = try MetalArgumentLayout.parse(payload: B.payload([
            B.Member("x", offset: 0, index: 0, .structure(inner)),
            B.Member("y", offset: 24, index: 10, .structure(inner)),
        ]))
        #expect(Self.offsets(l) == [0: 0, 1: 8, 2: 16, 10: 24, 11: 32, 12: 40])
        #expect(l.encodedLength == 48 && l.alignment == 8)
    }

    @Test func arraysPlaceEveryElement() throws {
        // Descriptor-built array: type 2, stride 8, index stride 0 → consecutive indices 10–13.
        // A resource array (array length 3) at id 1; an inline C array at id 20 (stride 4);
        // array<In2, 2> (buffer, sampler) at id 30 with stride 16 and index stride 2.
        let in2: [B.Member] = [
            B.Member(offset: 0, index: 0, .argument(.buffer())),
            B.Member(offset: 8, index: 1, .argument(.sampler())),
        ]
        let l = try MetalArgumentLayout.parse(payload: B.payload([
            B.Member(offset: 0, index: 1, .argument(.texture(arrayLength: 3))),
            B.Member(offset: 24, index: 10, .array(count: 4, stride: 8, indexStride: 0, element: .argument(.buffer()))),
            B.Member(offset: 56, index: 20, .array(count: 3, stride: 4, indexStride: 1,
                                                   element: .argument(.inline(dataType: 3, size: 4, alignment: 4)))),
            B.Member(offset: 72, index: 30, .array(count: 2, stride: 16, indexStride: 2, element: .structure(in2))),
        ]))
        #expect(Self.offsets(l) == [1: 0, 2: 8, 3: 16, 10: 24, 11: 32, 12: 40, 13: 48, 20: 56, 21: 60, 22: 64,
                                    30: 72, 31: 80, 32: 88, 33: 96])
        #expect(l.member(21)?.kind == .inlineData && l.member(33)?.kind == .sampler)
        #expect(l.encodedLength == 104 && l.alignment == 8)
    }

    @Test func aBuffersPointeeStructIsNotPartOfTheLayout() throws {
        let l = try MetalArgumentLayout.parse(payload: B.payload([
            B.Member("p", offset: 0, index: 0, .argument(.bufferTo([
                B.Member("x", offset: 0, index: 0, .argument(.inline(dataType: 6, size: 16, alignment: 16))),
                B.Member("y", offset: 16, index: 1, .argument(.inline(dataType: 3, size: 4, alignment: 4))),
            ]))),
            B.Member("t", offset: 8, index: 5, .argument(.texture())),
        ]))
        #expect(Self.offsets(l) == [0: 0, 5: 8] && l.encodedLength == 16 && l.alignment == 8)
    }

    /// A buffer's pointee struct with a member the grammar does not describe:
    /// the member itself is placed, and the parser finds the next top-level
    /// member after an argument record's terminator such that the rest parses
    /// to the end of the payload.
    @Test func anUnreadablePointeeIsSkipped() throws {
        let junk: [UInt8] = [3, 0, 0, 0, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 7, 0, 0, 0, 1, 2, 3]
        let pointee: [B.Member] = [
            B.Member("m", offset: 0, index: 0, .argument(.inline(dataType: 3, size: 4, alignment: 4))),
            B.Member("x", offset: 16, index: 1, .unknown(code: 11, bytes: junk)),
        ]
        let l = try MetalArgumentLayout.parse(payload: B.payload([
            B.Member("f", offset: 0, index: 0, .argument(.inline(dataType: 3, size: 4, alignment: 4))),
            B.Member("p", offset: 8, index: 10, .argument(.bufferTo(pointee))),
            B.Member("t", offset: 16, index: 11, .argument(.texture())),
            B.Member("s", offset: 24, index: 20, .argument(.sampler(arrayLength: 2))),
        ]))
        #expect(Self.offsets(l) == [0: 0, 10: 8, 11: 16, 20: 24, 21: 32] && l.encodedLength == 40 && l.skippedPointees == 1)
        // As the last member.
        let last = try MetalArgumentLayout.parse(payload: B.payload([
            B.Member("t", offset: 0, index: 1, .argument(.texture())),
            B.Member("p", offset: 8, index: 2, .argument(.bufferTo(pointee))),
        ]))
        #expect(Self.offsets(last) == [1: 0, 2: 8] && last.encodedLength == 16 && last.skippedPointees == 1)
        // No terminator after it: the description does not parse.
        var cut = B.payload([B.Member("p", offset: 0, index: 0, .argument(.bufferTo(pointee)))])
        cut.removeLast(8)
        #expect(throws: MetalDecodeError.self) { try MetalArgumentLayout.parse(payload: cut) }
    }

    @Test func malformedDescriptionsAreRejected() {
        let good = B.payload(Self.sparse)
        #expect(throws: MetalDecodeError.self) { try MetalArgumentLayout.parse(payload: Array(good.prefix(good.count - 3))) }
        #expect(throws: MetalDecodeError.self) { try MetalArgumentLayout.parse(payload: [UInt8](repeating: 0, count: 40)) }
        var badKind = good
        // The first argument record's kind byte: after magic, version, serial, count,
        // name "a\0", offset, index, code, u64, argument count, name "a\0".
        let at = 8 + 4 + 8 + 2 + 12 + 8 + 4 + 2
        #expect(badKind[at] == 2)
        badKind[at] = 7
        #expect(throws: MetalDecodeError.self) { try MetalArgumentLayout.parse(payload: badKind) }
    }

    // MARK: The service

    struct Device {
        let f: Fixture
        let argumentBuffer: UInt32, argumentBufferHandle: MetalHandle
        let data: UInt32, address: UInt64

        init(_ f: Fixture) {
            self.f = f
            f.backend.textureIDBase = 0x1000
            f.connect()
            _ = f.replyData(Build.message(12, Build.record(20) { $0.u32(0); $0.u64(1 << 20); $0.u16(0x20); $0.u16(0) }))
            func heapBuffer() -> UInt32 {
                Build.u32(f.replyData(Build.message(12, Build.record(24) { $0.u32(0); $0.u32(1); $0.u64(4096); $0.u64(0); $0.u64(0x20) })), 0)
            }
            argumentBuffer = heapBuffer()
            let data = heapBuffer()
            self.data = data
            argumentBufferHandle = f.backend.calls.compactMap { c -> MetalHandle? in
                if case let .createBuffer(h, _, _, _) = c { return h }
                return nil
            }[0]
            address = Build.u64(f.replyData(Build.message(12, Build.record(38) { $0.u32(data) })), 0)
        }

        /// Op 16 then op 17: (encoder ref, alignment, length).
        func encoder(_ members: [B.Member]?) -> (UInt32, UInt16, UInt16) {
            let body = members.map(B.recordBody) ?? [0, 0, 0, 0]
            let reply = f.replyData(Build.message(12, Build.record(16) { $0.append(body) }), on: 2)
            #expect(reply.count == 16 && Build.u32(reply, 2) == 0xFFFF_0001)
            let layout = Build.u32(reply, 0)
            let r = f.replyData(Build.message(12, Build.record(17) { $0.u32(0); $0.u32(layout) }), on: 2)
            #expect(r.count == 16)
            let word = Build.u32(r, 2)
            return (Build.u32(r, 0), UInt16(word & 0xFFFF), UInt16(word >> 16))
        }

        /// An op-19 set call (§4.3.4).
        func set(_ encoder: UInt32, kind: UInt8, index: UInt32, refs: [UInt32], offsets: [UInt64] = []) {
            _ = f.send(Build.message(12, Build.record(19) {
                $0.u32(encoder); $0.u32(UInt32(kind) | index << 8)
                $0.u32(0); $0.u32(UInt32(refs.count) << 8); $0.u64(0)
                if kind <= 1 {
                    for (i, r) in refs.enumerated() { $0.u32(r); $0.u64(i < offsets.count ? offsets[i] : 0) }
                } else {
                    for r in refs { $0.u32(r) }
                    for _ in refs { $0.u64(0) }
                }
            }), on: 2)
        }

        func writes(after n: Int = 0) -> [(Int, UInt64)] {
            f.backend.calls.dropFirst(n).compactMap { c -> (Int, UInt64)? in
                guard case let .writeBuffer(h, offset, bytes) = c, h == argumentBufferHandle, bytes.count == 8 else { return nil }
                return (offset, Build.u64(bytes, 0))
            }
        }

        func constantData(_ encoder: UInt32, index: UInt32) -> UInt64 {
            Build.u64(f.replyData(Build.message(12, Build.record(35) { $0.u32(encoder); $0.u32(argumentBuffer); $0.u32(index); $0.u32(0) }), on: 2), 0)
        }
    }

    @Test func setCallsWriteAtTheLayoutsOffsets() throws {
        let d = Device(Fixture())
        let (encoder, alignment, length) = d.encoder(Self.sparse)
        #expect(alignment == 8 && length == 32)
        let texture = Build.u32(d.f.replyData(Build.message(8, Build.record(1) {
            $0.append(Build.textureWords(usage: 1, format: 80, width: 8, height: 8, levels: 1))
        })), 0)
        let sampler = Build.u32(d.f.replyData(Build.message(8, Build.record(3) {
            $0.append(MetalDescriptorCodec.encodeSampler(MetalSamplerDescriptor()))
        })), 0)
        let samplerID = Build.u64(d.f.replyData(Build.message(12, Build.record(39) { $0.u32(sampler); $0.u32(8) })), 0)
        let textureHandle = try #require(d.f.backend.calls.compactMap { c -> MetalHandle? in
            if case let .createTexture(h, _, _) = c { return h }
            return nil
        }.first)
        let before = d.f.backend.calls.count
        d.set(encoder, kind: 0, index: 0, refs: [d.argumentBuffer], offsets: [512])
        d.set(encoder, kind: 1, index: 200, refs: [d.data, 0], offsets: [16, 0])   // range: 200 and 201 (nil)
        d.set(encoder, kind: 2, index: 230, refs: [texture])
        d.set(encoder, kind: 3, index: 231, refs: [sampler])
        let w = d.writes(after: before)
        #expect(w.map(\.0) == [512, 520, 528, 536], "\(w)")
        #expect(w.map(\.1) == [d.address + 16, 0, 0x1000 + textureHandle.raw, samplerID], "\(w)")
        #expect(d.f.core.statistics.refused["12:19"] == nil && d.f.core.statistics.refused["12:16"] == nil)
        // constantDataAtIndex: the argument-buffer offset plus the member's.
        #expect(d.constantData(encoder, index: 230) == 512 + 16)
        // An index the layout lacks: logged, nothing written.
        d.set(encoder, kind: 1, index: 202, refs: [d.data])
        #expect(d.writes(after: before).count == 4)
        #expect(d.f.logs.contains { $0.contains("index 202 is not in its layout") })
    }

    @Test func twentyFourBitIndicesAndRangeForms() {
        let d = Device(Fixture())
        // Buffers 1000–1002 and samplers 1003–1004 (a dense run of ids starting at 1000).
        let (encoder, _, length) = d.encoder((0..<5).map {
            B.Member(offset: 8 * $0, index: 1000 + $0, .argument($0 < 3 ? .buffer() : .sampler()))
        })
        #expect(length == 40)
        let s1 = Build.u32(d.f.replyData(Build.message(8, Build.record(3) { $0.append(MetalDescriptorCodec.encodeSampler(MetalSamplerDescriptor())) })), 0)
        let before = d.f.backend.calls.count
        d.set(encoder, kind: 0, index: 0, refs: [d.argumentBuffer], offsets: [0])
        d.set(encoder, kind: 1, index: 1000, refs: [d.data, d.data, d.data], offsets: [0, 8, 64])
        d.set(encoder, kind: 3, index: 1003, refs: [s1, 0])
        let w = d.writes(after: before)
        #expect(w.map(\.0) == [0, 8, 16, 24, 32], "\(w)")
        #expect(w.prefix(3).map(\.1) == [d.address, d.address + 8, d.address + 64] && w.last?.1 == 0)
    }

    @Test func encodersWithoutADescriptionKeepTheOldRule() {
        let d = Device(Fixture())
        let (encoder, alignment, length) = d.encoder(nil)
        #expect(alignment == 8 && length == 24)
        #expect(d.f.core.statistics.refused["12:16"] == 1)
        let before = d.f.backend.calls.count
        d.set(encoder, kind: 0, index: 0, refs: [d.argumentBuffer], offsets: [256])
        d.set(encoder, kind: 1, index: 3, refs: [d.data], offsets: [16])
        d.set(encoder, kind: 1, index: 4, refs: [0])
        #expect(d.writes(after: before).map(\.0) == [256 + 24, 256 + 32])
        #expect(d.constantData(encoder, index: 2) == 256 + 16)
        #expect(d.f.logs.filter { $0.contains("has no layout description") }.count == 1)
    }

    /// A restore keeps each encoder's table and argument buffer: a set call
    /// after it lands at the layout's offset without a new kind-0 call.
    @Test func restoredEncodersKeepTheirLayouts() throws {
        let d = Device(Fixture())
        let (encoder, _, _) = d.encoder(Self.sparse)
        d.set(encoder, kind: 0, index: 0, refs: [d.argumentBuffer], offsets: [64])
        d.set(encoder, kind: 1, index: 201, refs: [d.data], offsets: [0])
        let state = try #require(d.f.core.trySnapshotState(log: { _ in }))
        let g = Fixture()
        let report = g.core.restoreState(try SnapshotFieldReader(state.bytes))
        #expect(report.failures == 0 && report.argumentMembers == 1)
        let restored = Device.restored(g, argumentBuffer: d.argumentBuffer, handle: d.argumentBufferHandle, data: d.data)
        let before = g.backend.calls.count
        restored.set(encoder, kind: 1, index: 230, refs: [0])
        #expect(restored.writes(after: before).map(\.0) == [64 + 16])
        #expect(restored.constantData(encoder, index: 231) == 64 + 24)
    }
}

extension ArgumentLayoutTests.Device {
    /// A device over a restored core (no new objects).
    static func restored(_ f: CoreTests.Fixture, argumentBuffer: UInt32, handle: MetalHandle, data: UInt32) -> Self {
        Self(f: f, argumentBuffer: argumentBuffer, argumentBufferHandle: handle, data: data, address: 0)
    }

    private init(f: CoreTests.Fixture, argumentBuffer: UInt32, argumentBufferHandle: MetalHandle, data: UInt32, address: UInt64) {
        self.f = f
        self.argumentBuffer = argumentBuffer
        self.argumentBufferHandle = argumentBufferHandle
        self.data = data
        self.address = address
    }
}
