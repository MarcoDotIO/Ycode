import Foundation
import Testing
@testable import YcodeMetalHost
import YcodeDarwinKernel
import YcodeXPC

/// Snapshot and replay of the service (snapshot.md §8 option 2): the tables,
/// the recipes, and a replay on a fresh back end under the old handles.
@Suite struct SnapshotReplayTests {
    typealias Fixture = CoreTests.Fixture

    @Test func replayMakesEveryLiveObjectAgainUnderItsHandle() throws {
        let f = Fixture()
        f.connect()
        let fn = Build.record(15) { $0.u32(0); $0.u32(0); $0.u32(0) }
        let ir = [UInt8](repeating: 0x4D, count: 300)
        _ = f.replyData(Build.message(15, fn, [("functionIR", .data(ir))]))       // function ref 1
        _ = f.replyData(Build.message(15, fn, [("functionIR", .data(ir + [1]))])) // function ref 2
        let payload = MetalKeyedPayloadBuilder.renderPipeline(top: [(1, 1), (2, 2)], label: "quad",
                                                              colorAttachments: [[(0, 0), (1, 80), (2, 1), (4, 5), (7, 5)]])
        let rp = Build.record(14) { $0.u32(0); $0.u32(UInt32(payload.count)); $0.append(payload) }
        _ = f.replyData(Build.message(12, rp), on: 2)                               // pipeline ref 1
        let tex = Build.record(1) { $0.append(Build.textureWords(usage: 1, format: 80, width: 8, height: 8, levels: 2)) }
        _ = f.replyData(Build.message(8, tex))                                      // texture ref 1
        _ = f.replyData(Build.message(12, Build.record(7) { $0.u32(0); $0.u32(1); $0.u32(81) }))  // view ref 2
        _ = f.send(["messageType": .uint64(1), "length": .uint64(4096), "options": .uint64(0x20), "bufferIndex": .uint64(0)], on: 1)
        // The pipeline's vertex function goes; the pipeline keeps it alive as a recipe.
        _ = f.send(Build.message(14, Build.record(1005) { $0.u32(1) }), on: 1)
        let before = f.backend.calls
        let handles = before.compactMap { c -> MetalHandle? in
            switch c {
            case let .createFunction(h, _), let .createRenderPipeline(h, _), let .createTexture(h, _, _),
                 let .createTextureView(h, _, _), let .createBuffer(h, _, _, _): return h
            default: return nil
            }
        }
        #expect(handles.count == 6)

        let state = try #require(f.core.trySnapshotState(log: { _ in }))
        let reader = try SnapshotFieldReader(state.bytes)

        let g = Fixture()
        let report = g.core.restoreState(reader)
        #expect(report.processes == 1 && report.objects == 5 && report.ghosts == 1 && report.failures == 0)
        let replayed = g.backend.calls
        // The released function is made for the pipeline and released after.
        guard case let .createFunction(f1, 300) = replayed.first, f1 == handles[0] else {
            Issue.record("calls \(replayed)")
            return
        }
        #expect(replayed.last == .release(f1))
        if let i = replayed.firstIndex(where: { if case .createRenderPipeline = $0 { true } else { false } }),
           case let .createRenderPipeline(h, desc) = replayed[i] {
            #expect(h == handles[2] && desc.vertexFunction == handles[0] && desc.fragmentFunction == handles[1])
        } else {
            Issue.record("no pipeline in \(replayed)")
        }
        #expect(replayed.contains(.createTextureView(handles[4], parent: handles[3], MetalTextureViewDescriptor(pixelFormat: 81))))
        // The restored core goes on with the same refs and fresh handles: the
        // next texture gets ref 4 (texture, view, buffer hold 1–3) and a handle after every old one.
        #expect(g.replyData(Build.message(8, tex)) == [4, 0, 0, 0])
        if case let .createTexture(h, _, _) = g.backend.calls.last { #expect(h > handles.max()!) } else { Issue.record("no texture") }
        // Release of a restored object reaches the back end with its old handle.
        _ = g.send(Build.message(14, Build.record(1007) { $0.u32(1) }), on: 1)
        #expect(g.backend.calls.last == .release(handles[2]))
    }

    /// A restore keeps the textures' heap slots (the back end is asked to
    /// reserve them before the replay) and writes every argument-encoder
    /// member again whose object's ID changed on the new back end
    /// (visionos.md §10.21): the warm boot's argument buffers name the
    /// restored textures, not the slots the cold boot's had.
    @Test func restoreKeepsSlotsAndRewritesArgumentMembers() throws {
        let f = Fixture()
        f.backend.textureIDBase = 1000
        f.connect()
        _ = f.replyData(Build.message(12, Build.record(20) { $0.u32(0); $0.u64(1 << 20); $0.u16(0x20); $0.u16(0) }))
        let argumentBuffer = Build.u32(f.replyData(Build.message(12, Build.record(24) {
            $0.u32(0); $0.u32(1); $0.u64(4096); $0.u64(0); $0.u64(0x20)
        })), 0)
        let tex = Build.record(1) { $0.append(Build.textureWords(usage: 1, format: 80, width: 8, height: 8, levels: 1)) }
        let texture = Build.u32(f.replyData(Build.message(8, tex)), 0)
        let layout = Build.u32(f.replyData(Build.message(12, Build.record(16) { $0.u32(0) })), 0)
        let encoder = Build.u32(f.replyData(Build.message(12, Build.record(17) { $0.u32(0); $0.u32(layout) })), 0)
        func set(kind: UInt8, index: UInt8, object: UInt32, offset: UInt64) {
            _ = f.send(Build.message(12, Build.record(19) {
                $0.u32(encoder); $0.u8(kind); $0.u8(index); $0.u16(0)
                $0.u32(0); $0.u32(0x100); $0.u32(0); $0.u32(0)
                $0.u32(object); $0.u64(offset)
            }), on: 1)
        }
        set(kind: 0, index: 0, object: argumentBuffer, offset: 64)
        set(kind: 2, index: 2, object: texture, offset: 0)
        let textureHandle = try #require(f.backend.calls.compactMap { c -> MetalHandle? in
            if case let .createTexture(h, _, _) = c { return h }
            return nil
        }.first)
        var cold = MetalByteWriter()
        cold.u64(1000 + textureHandle.raw)
        #expect(f.backend.calls.last == .writeBuffer(try #require(f.backend.calls.compactMap { c -> MetalHandle? in
            if case let .createBuffer(h, _, _, _) = c { return h }
            return nil
        }.first), offset: 64 + 16, bytes: cold.bytes))

        let state = try #require(f.core.trySnapshotState(log: { _ in }))
        let g = Fixture()
        g.backend.textureIDBase = 5000
        let report = g.core.restoreState(try SnapshotFieldReader(state.bytes))
        #expect(report.failures == 0)
        // The slot the texture had is reserved before anything is made, and an empty call ends the restore.
        let reserved = g.backend.reservations
        #expect(reserved.count == 2 && reserved.last.map { $0.textures.isEmpty && $0.samplers.isEmpty } == true)
        #expect(reserved.first?.textures[textureHandle].map { $0.index == 1000 + UInt32(textureHandle.raw) && $0.count == 1 } == true)
        // This back end gave it another ID: the member is written again with it.
        var warm = MetalByteWriter()
        warm.u64(5000 + textureHandle.raw)
        let writes = g.backend.calls.compactMap { c -> (Int, [UInt8])? in
            if case let .writeBuffer(_, offset, bytes) = c { return (offset, bytes) }
            return nil
        }
        #expect(writes.count == 1 && writes.first.map { $0.0 == 64 + 16 && $0.1 == warm.bytes } == true, "\(writes)")
        #expect(report.argumentMembers == 1 && report.argumentMembersChanged == 1 && report.textureIDsChanged == 1, "\(report)")
        // A snapshot of the restored core keeps the member (now with the new value).
        let again = try #require(g.core.trySnapshotState(log: { _ in }))
        let h = Fixture()
        h.backend.textureIDBase = 5000
        let second = h.core.restoreState(try SnapshotFieldReader(again.bytes))
        #expect(second.argumentMembers == 1 && second.argumentMembersChanged == 0 && second.slotsKept == 1)
    }

    @Test func snapshotWaitsForCommandBuffersInFlight() throws {
        let f = Fixture(completesImmediately: false)
        f.connect()
        _ = f.send(["messageType": .uint64(7)], on: 0)
        _ = f.send(["messageType": .uint64(6), "commandBufferRef": .uint64(1), "commandQueue": .uint64(1),
                    "segments": .array([])], on: 0)
        #expect(f.core.snapshotBusyReason != nil)
        #expect(f.core.trySnapshotState(log: { _ in }) == nil)
        for p in f.backend.pending { p.completed(4) }
        f.core.drainEvents()
        #expect(f.core.snapshotBusyReason == nil)
        #expect(f.core.trySnapshotState(log: { _ in }) != nil)
    }
}
