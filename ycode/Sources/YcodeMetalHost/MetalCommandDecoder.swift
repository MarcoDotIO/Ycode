// The command-buffer decoder (metal-sim-protocol.md §8): segments of a
// messageType-6 submission → passes of commands, guest refs → handles.

import Foundation

/// The kinds of guest refs (spec §3). Buffers and textures share one counter.
public enum MetalRefKind: String, Sendable, CaseIterable {
    case resource  // buffers and textures
    case function, renderPipeline, computePipeline, sampler, depthStencil
    case heap, fence, event, queue, argumentLayout, argumentEncoder
}

/// Encoder kinds of a segment header (spec §8.1).
public enum MetalEncoderKind {
    public static let render: UInt8 = 0
    public static let compute: UInt8 = 1
    public static let blit: UInt8 = 2
    public static let event: UInt8 = 3
}

/// A segment header: u32 bytes used (header included), u8 encoder kind,
/// u8 continues the previous segment's encoder, u8 continues in the next, u8 0.
public struct MetalSegmentHeader: Equatable, Sendable {
    public var used: Int
    public var kind: UInt8
    public var continuesPrevious: Bool
    public var continuesInNext: Bool
    public static let size = 8

    public init(used: Int, kind: UInt8, continuesPrevious: Bool = false, continuesInNext: Bool = false) {
        self.used = used
        self.kind = kind
        self.continuesPrevious = continuesPrevious
        self.continuesInNext = continuesInNext
    }
}

public struct MetalCommandDecoder {
    /// Maps a guest ref of a kind to a handle; nil for unknown refs.
    public typealias Resolve = (MetalRefKind, UInt32) -> MetalHandle?

    let resolve: Resolve
    var diagnostics: [String] = []
    var unknownCount = 0
    /// Ops seen as unknown (op → count).
    public private(set) var unknownOps: [UInt32: Int] = [:]

    public init(resolve: @escaping Resolve) { self.resolve = resolve }

    /// Decodes a submission's segments, in order.
    public static func decode(segments: [[UInt8]], process: MetalProcessID, queue: MetalHandle?, commandBufferRef: UInt64,
                              resolve: @escaping Resolve) -> (MetalCommandBuffer, unknownOps: [UInt32: Int]) {
        var d = MetalCommandDecoder(resolve: resolve)
        let passes = d.decode(segments)
        return (MetalCommandBuffer(process: process, queue: queue, commandBufferRef: commandBufferRef, passes: passes,
                                   unknownRecordCount: d.unknownCount, diagnostics: d.diagnostics), d.unknownOps)
    }

    public static func header(_ segment: [UInt8]) -> MetalSegmentHeader? {
        guard segment.count >= MetalSegmentHeader.size else { return nil }
        var r = ByteReader(segment)
        guard let used = try? r.u32(), let kind = try? r.u8(), let prev = try? r.u8(), let next = try? r.u8() else { return nil }
        return MetalSegmentHeader(used: Int(used), kind: kind, continuesPrevious: prev != 0, continuesInNext: next != 0)
    }

    /// The records of one segment (between the header and `used`). A
    /// malformed record ends the segment with a diagnostic.
    mutating func records(_ segment: [UInt8], used: Int, index: Int) -> [MetalRecord] {
        var out: [MetalRecord] = []
        var off = MetalSegmentHeader.size
        while off + 8 <= used {
            var r = ByteReader(segment, from: off, to: used)
            let op = (try? r.u32()) ?? 0, length = Int((try? r.u32()) ?? 0)
            guard length >= 8, off + length <= used else {
                diagnostics.append("segment \(index): record op \(op) at \(off) has length \(length) (used \(used))")
                return out
            }
            out.append(MetalRecord(op: op, body: Array(segment[(off + 8)..<(off + length)])))
            off += length
        }
        if off != used { diagnostics.append("segment \(index): \(used - off) stray bytes at \(off)") }
        return out
    }

    enum Open {
        case render(MetalRenderPass)
        case compute([MetalComputeCommand])
        case blit([MetalBlitCommand])
        case event([MetalEventCommand])
        case unknown(UInt8, [MetalUnknownRecord])

        var pass: MetalPass {
            switch self {
            case let .render(p): .render(p)
            case let .compute(c): .compute(c)
            case let .blit(c): .blit(c)
            case let .event(c): .event(c)
            case let .unknown(k, r): .unknown(kind: k, records: r)
            }
        }

        var kind: UInt8 {
            switch self {
            case .render: MetalEncoderKind.render
            case .compute: MetalEncoderKind.compute
            case .blit: MetalEncoderKind.blit
            case .event: MetalEncoderKind.event
            case let .unknown(k, _): k
            }
        }
    }

    mutating func decode(_ segments: [[UInt8]]) -> [MetalPass] {
        var passes: [MetalPass] = []
        var open: Open?
        var expectContinuation = false
        for (i, segment) in segments.enumerated() {
            guard let h = Self.header(segment), h.used >= MetalSegmentHeader.size, h.used <= segment.count else {
                diagnostics.append("segment \(i): bad header (\(segment.count) bytes)")
                continue
            }
            if h.continuesPrevious, let o = open, o.kind == h.kind {
                // Same encoder.
            } else {
                if h.continuesPrevious { diagnostics.append("segment \(i): continues an encoder that is not open") }
                if let o = open { passes.append(o.pass) }
                open = nil
            }
            if !h.continuesPrevious && expectContinuation {
                diagnostics.append("segment \(i): previous segment announced a continuation")
            }
            expectContinuation = h.continuesInNext
            for rec in records(segment, used: h.used, index: i) {
                apply(rec, kind: h.kind, to: &open)
            }
            if open == nil {
                // An encoder segment without records still makes a pass (e.g. a render pass with only a clear).
                open = start(kind: h.kind, first: nil)
            }
        }
        if let o = open { passes.append(o.pass) }
        return passes
    }

    func start(kind: UInt8, first: MetalRenderPassDescriptor?) -> Open {
        switch kind {
        case MetalEncoderKind.render: .render(MetalRenderPass(descriptor: first))
        case MetalEncoderKind.compute: .compute([])
        case MetalEncoderKind.blit: .blit([])
        case MetalEncoderKind.event: .event([])
        default: .unknown(kind, [])
        }
    }

    mutating func noteUnknown(_ op: UInt32) {
        unknownCount += 1
        unknownOps[op, default: 0] += 1
    }

    /// Appends to the open encoder's list. The payload is taken out of
    /// `open` (which is cleared first) so that the list has one owner and
    /// grows in place: copying it out while `open` still referred to it made
    /// every append copy the whole list (quadratic in the commands of a pass;
    /// stage8-contract.md §15).
    /// `YCODE_METAL_RECORD_FAST=0`: keep the old reference during the
    /// append (the copying behaviour, for A/B measurements only).
    static let copyingAppend = ProcessInfo.processInfo.environment["YCODE_METAL_RECORD_FAST"] == "0"

    mutating func apply(_ rec: MetalRecord, kind: UInt8, to open: inout Open?) {
        switch kind {
        case MetalEncoderKind.render:
            if rec.op == 26 {
                let desc: MetalRenderPassDescriptor?
                do { desc = try renderPassDescriptor(rec.body) } catch {
                    diagnostics.append("render pass descriptor: \(error)")
                    desc = nil
                }
                if case let .render(p)? = open, p.descriptor == nil, p.commands.isEmpty {
                    open = .render(MetalRenderPass(descriptor: desc))
                } else if case let .render(p)? = open {
                    // A second begin record within one encoder: keep it as its own pass.
                    diagnostics.append("render encoder: begin-pass record after \(p.commands.count) commands")
                    open = .render(MetalRenderPass(descriptor: desc))
                } else {
                    open = .render(MetalRenderPass(descriptor: desc))
                }
                return
            }
            if open == nil { open = start(kind: kind, first: nil) }
            guard case var .render(p) = open else { return }
            let held = Self.copyingAppend ? open : nil
            open = nil
            if let many = multiSlotRenderCommands(rec) {
                p.commands.append(contentsOf: many)
            } else {
                let c = renderCommand(rec)
                if case .unknown = c { noteUnknown(rec.op) }
                if case let .setStoreAction(index, action) = c { Self.applyStoreAction(&p, index: index, action: action) }
                p.commands.append(c)
            }
            withExtendedLifetime(held) {}
            open = .render(p)
        case MetalEncoderKind.compute:
            if open == nil { open = .compute([]) }
            guard case var .compute(cs) = open else { return }
            let held = Self.copyingAppend ? open : nil
            open = nil
            if let many = multiSlotComputeCommands(rec) {
                cs.append(contentsOf: many)
            } else {
                let c = computeCommand(rec)
                if case .unknown = c { noteUnknown(rec.op) }
                cs.append(c)
            }
            withExtendedLifetime(held) {}
            open = .compute(cs)
        case MetalEncoderKind.blit:
            if open == nil { open = .blit([]) }
            guard case var .blit(cs) = open else { return }
            open = nil
            let c = blitCommand(rec)
            if case .unknown = c { noteUnknown(rec.op) }
            cs.append(c)
            open = .blit(cs)
        case MetalEncoderKind.event:
            if open == nil { open = .event([]) }
            guard case var .event(cs) = open else { return }
            open = nil
            let c = eventCommand(rec)
            if case .unknown = c { noteUnknown(rec.op) }
            cs.append(c)
            open = .event(cs)
        default:
            if open == nil { open = .unknown(kind, []) }
            guard case .unknown(let k, var rs) = open else { return }
            open = nil
            noteUnknown(rec.op)
            rs.append(MetalUnknownRecord(op: rec.op, body: rec.body))
            open = .unknown(k, rs)
        }
    }

    // MARK: Refs

    func ref(_ kind: MetalRefKind, _ v: UInt32) -> MetalHandle? {
        v == 0 ? nil : resolve(kind, v)
    }

    func refs(_ r: inout ByteReader, count: Int, _ kind: MetalRefKind) throws -> [MetalHandle] {
        guard count <= r.remaining / 4 else { throw MetalDecodeError.truncated(need: count * 4, have: r.remaining) }
        var out: [MetalHandle] = []
        for _ in 0..<count { if let h = ref(kind, try r.u32()) { out.append(h) } }
        return out
    }

    /// Heap refs of record 27: from byte 6 (unaligned), after u32 count and u16 stages.
    func unalignedRefs(_ body: [UInt8], at start: Int, count: Int, _ kind: MetalRefKind) throws -> [MetalHandle] {
        guard count >= 0, start + 4 * count <= body.count else {
            throw MetalDecodeError.truncated(need: start + 4 * max(count, 0), have: body.count)
        }
        var out: [MetalHandle] = []
        for i in 0..<count {
            let o = start + 4 * i
            let v = UInt32(body[o]) | UInt32(body[o + 1]) << 8 | UInt32(body[o + 2]) << 16 | UInt32(body[o + 3]) << 24
            if let h = ref(kind, v) { out.append(h) }
        }
        return out
    }

    /// A deferred store action (records 102, 105, 120) changes the store
    /// action of the open pass's attachment (Metal: the action given at
    /// `endEncoding` time is the one that counts; a pass begun with
    /// `MTLStoreActionUnknown` must set one). Nothing for a pass without a
    /// descriptor or without that attachment.
    static func applyStoreAction(_ p: inout MetalRenderPass, index: Int, action: UInt32) {
        guard var d = p.descriptor else { return }
        let a = UInt16(truncatingIfNeeded: action)
        switch index {
        case MetalRenderCommand.depthAttachment: d.depth?.storeAction = a
        case MetalRenderCommand.stencilAttachment: d.stencil?.storeAction = a
        default:
            guard let i = d.colorAttachments.firstIndex(where: { $0.index == index }) else { return }
            d.colorAttachments[i].attachment.storeAction = a
        }
        p.descriptor = d
    }

    // MARK: Render pass descriptor (§8.6)

    func attachment(_ body: [UInt8], at base: Int) throws -> (MetalRenderPassAttachment, texture: UInt32) {
        var r = ByteReader(body, from: base)
        let t = try r.u32(), resolveRef = try r.u32()
        let level = try r.int16(), slice = try r.int16()
        let w12 = try r.u32(), w16 = try r.u32()
        let load = try r.u16(), store = try r.u16()
        let w24 = try r.u32()
        return (MetalRenderPassAttachment(texture: ref(.resource, t), resolveTexture: ref(.resource, resolveRef), level: level,
                                          slice: slice, loadAction: load, storeAction: store, openWords: [w12, w16, w24]), t)
    }

    func renderPassDescriptor(_ body: [UInt8]) throws -> MetalRenderPassDescriptor {
        guard body.count >= 584 else { throw MetalDecodeError.truncated(need: 584, have: body.count) }
        var d = MetalRenderPassDescriptor()
        let (depth, depthRef) = try attachment(body, at: 0)
        if depthRef != 0 { d.depth = depth }
        var r = ByteReader(body, from: 28)
        d.clearDepth = try r.f64()
        let (stencil, stencilRef) = try attachment(body, at: 40)
        if stencilRef != 0 { d.stencil = stencil }
        r = ByteReader(body, from: 68)
        d.clearStencil = try r.u32()
        for n in 0..<8 {
            let base = 76 + 60 * n
            let (a, t) = try attachment(body, at: base)
            guard t != 0 else { continue }
            var c = ByteReader(body, from: base + 28)
            let color = [try c.f64(), try c.f64(), try c.f64(), try c.f64()]
            d.colorAttachments.append(MetalColorAttachment(index: n, attachment: a, clearColor: color))
        }
        r = ByteReader(body, from: 556)
        d.visibilityResultBuffer = ref(.resource, try r.u32())
        r = ByteReader(body, from: 568)
        d.renderTargetWidth = try r.int64()
        d.renderTargetHeight = try r.int64()
        return d
    }

    // MARK: Render records (§8.3)

    func renderCommand(_ rec: MetalRecord) -> MetalRenderCommand {
        do {
            if let c = try renderCommandThrowing(rec) { return c }
        } catch {}
        return .unknown(op: rec.op, body: rec.body)
    }

    /// Range forms of the binding records (`setFragmentTextures:withRange:`
    /// and the like) and `setViewports:count:`: the single-slot record with
    /// a count above 1 and one ref (and, for buffers, one offset) per slot,
    /// and op 131 with a count and that many viewports. Seen in Ycode's
    /// guest (visionos.md §10.11: wakeboardd's compositor binds its layer
    /// textures with op 114, count 2, 16-byte body); nil when the record is
    /// not of such a form, so the single-slot decoding applies.
    func multiSlotRenderCommands(_ rec: MetalRecord) -> [MetalRenderCommand]? {
        var r = ByteReader(rec.body)
        switch rec.op {
        case 114, 129, 112, 127:
            guard rec.body.count >= 8, let index = try? r.int32(), let count = try? r.u32(), count > 1,
                  rec.body.count == 8 + 4 * Int(count) else { return nil }
            var out: [MetalRenderCommand] = []
            for i in 0..<Int(count) {
                guard let v = try? r.u32() else { return nil }
                switch rec.op {
                case 114, 129:
                    out.append(.setTexture(stage: rec.op == 129 ? .vertex : .fragment, index: index + i, texture: ref(.resource, v)))
                default:
                    out.append(.setSamplerState(stage: rec.op == 127 ? .vertex : .fragment, index: index + i,
                                                sampler: ref(.sampler, v), lodMinClamp: nil, lodMaxClamp: nil))
                }
            }
            return out
        case 110, 125:
            // Per slot a pair: u32 ref, then its u64 offset (unaligned;
            // VISIONOS-OBS4's probe, metal-sim-protocol.md §8.3).
            guard let pairs = bufferPairs(rec) else { return nil }
            return pairs.map { .setBuffer(stage: rec.op == 125 ? .vertex : .fragment, index: $0.index, buffer: $0.buffer, offset: $0.offset) }
        case 118:
            // `setScissorRects:count:`: u32 count, u32 0, then per rect four
            // u64; the first rect (Ycode's pipelines have one viewport).
            guard let count = try? r.u32(), count >= 1, rec.body.count == 8 + 32 * Int(count), (try? r.u32()) != nil,
                  let x = try? r.int64(), let y = try? r.int64(), let w = try? r.int64(), let h = try? r.int64() else { return nil }
            return [.setScissorRect(MetalScissorRect(x: x, y: y, width: w, height: h))]
        case 131:
            guard let count = try? r.u32(), count >= 1, rec.body.count == 4 + 48 * Int(count),
                  let x = try? r.f64(), let y = try? r.f64(), let w = try? r.f64(), let h = try? r.f64(),
                  let zn = try? r.f64(), let zf = try? r.f64() else { return nil }
            // The first viewport (Ycode's pipelines have one).
            return [.setViewport(MetalViewport(x: x, y: y, width: w, height: h, znear: zn, zfar: zf))]
        default:
            return nil
        }
    }

    /// The buffer bindings of a range record (110, 125, 203): u32 first
    /// index, u32 count, then per slot u32 ref and u64 offset. Nil when the
    /// count is 1 (the single-slot decoding applies) or the body does not fit.
    func bufferPairs(_ rec: MetalRecord) -> [(index: Int, buffer: MetalHandle?, offset: Int)]? {
        var r = ByteReader(rec.body)
        guard rec.body.count >= 8, let index = try? r.int32(), let count = try? r.u32(), count > 1,
              rec.body.count == 8 + 12 * Int(count) else { return nil }
        var out: [(index: Int, buffer: MetalHandle?, offset: Int)] = []
        for i in 0..<Int(count) {
            guard let b = try? r.u32(), let off = try? r.int64() else { return nil }
            out.append((index + i, ref(.resource, b), off))
        }
        return out
    }

    /// Range forms of the compute binding records: 203 (buffers, pairs as
    /// 110/125), 204 (samplers) and 206 (textures), one ref per slot.
    func multiSlotComputeCommands(_ rec: MetalRecord) -> [MetalComputeCommand]? {
        switch rec.op {
        case 203:
            return bufferPairs(rec)?.map { .setBuffer(index: $0.index, buffer: $0.buffer, offset: $0.offset) }
        case 204, 206:
            var r = ByteReader(rec.body)
            guard rec.body.count >= 8, let index = try? r.int32(), let count = try? r.u32(), count > 1,
                  rec.body.count == 8 + 4 * Int(count) else { return nil }
            var out: [MetalComputeCommand] = []
            for i in 0..<Int(count) {
                guard let v = try? r.u32() else { return nil }
                out.append(rec.op == 206 ? .setTexture(index: index + i, texture: ref(.resource, v))
                           : .setSamplerState(index: index + i, sampler: ref(.sampler, v), lodMinClamp: nil, lodMaxClamp: nil))
            }
            return out
        default:
            return nil
        }
    }

    /// One binding slot: u32 index, u32 count (1 is the only value seen).
    func slot(_ r: inout ByteReader) throws -> Int? {
        let index = try r.int32(), count = try r.u32()
        return count == 1 ? index : nil
    }

    /// Diagnostics: draws larger than `largeDraw` vertices × instances are
    /// reported here with their record (op and body), once per op and size.
    nonisolated(unsafe) public static var anomalyLog: ((String) -> Void)?
    public static let largeDraw = 1 << 26

    /// Diagnostics: op-29 records whose base-instance word has a non-zero
    /// high half (ignored), the first 8 with their body.
    nonisolated(unsafe) static var shortBaseInstanceHighLogged = 0
    func noteShortBaseInstanceHigh(_ rec: MetalRecord) {
        guard Self.shortBaseInstanceHighLogged < 8, let log = Self.anomalyLog else { return }
        Self.shortBaseInstanceHighLogged += 1
        log("metal: render record op 29 with bytes in the high half of its base-instance word (ignored): body "
            + rec.body.map { String(format: "%02x", $0) }.joined())
    }

    /// Reports a draw record whose size is beyond any plausible draw.
    func checked(_ rec: MetalRecord, _ command: MetalRenderCommand) -> MetalRenderCommand {
        let work: Int
        switch command {
        case .draw(let d): work = d.vertexCount.multipliedReportingOverflow(by: d.instanceCount).partialValue
        case .drawIndexed(let d): work = d.indexCount.multipliedReportingOverflow(by: d.instanceCount).partialValue
        default: return command
        }
        if work > Self.largeDraw || work < 0, let log = Self.anomalyLog {
            log("metal: render record op \(rec.op) draws \(work) vertices: body " + rec.body.map { String(format: "%02x", $0) }.joined())
        }
        return command
    }

    func renderCommandThrowing(_ rec: MetalRecord) throws -> MetalRenderCommand? {
        var r = ByteReader(rec.body)
        switch rec.op {
        case 0:
            let t = try r.u32()
            return checked(rec, .draw(MetalDraw(primitiveType: t, vertexStart: try r.int64(), vertexCount: try r.int64())))
        case 1:
            let t = try r.u32()
            return .draw(MetalDraw(primitiveType: t, vertexStart: try r.int16(), vertexCount: try r.int16()))
        case 2:
            // Long instanced form (values ≥ 65 536; agent H's capture, metal-sim-protocol.md §8.3).
            let s = try r.int64(), n = try r.int64(), i = try r.int64(), t = try r.u32()
            return checked(rec, .draw(MetalDraw(primitiveType: t, vertexStart: s, vertexCount: n, instanceCount: i)))
        case 4:
            let s = try r.int64(), n = try r.int64(), i = try r.int64(), b = try r.int64(), t = try r.u32()
            return checked(rec, .draw(MetalDraw(primitiveType: t, vertexStart: s, vertexCount: n, instanceCount: i, baseInstance: b)))
        case 8:
            let t = try r.u16(), it = try r.u16(), ib = try r.u32(), n = try r.int64(), off = try r.int64(), i = try r.int64()
            return checked(rec, .drawIndexed(MetalIndexedDraw(primitiveType: UInt32(t), indexType: UInt32(it), indexBuffer: ref(.resource, ib),
                                                              indexBufferOffset: off, indexCount: n, instanceCount: i)))
        case 3:
            let s = try r.int16(), n = try r.int16(), i = try r.int16(), t = try r.u16()
            return .draw(MetalDraw(primitiveType: UInt32(t), vertexStart: s, vertexCount: n, instanceCount: i))
        case 5:
            let s = try r.int16(), n = try r.int16(), i = try r.int16(), b = try r.int16(), t = try r.u32()
            return .draw(MetalDraw(primitiveType: t, vertexStart: s, vertexCount: n, instanceCount: i, baseInstance: b))
        case 6:
            let t = try r.u16(), it = try r.u16(), ib = try r.u32(), n = try r.int64(), off = try r.int64()
            return checked(rec, .drawIndexed(MetalIndexedDraw(primitiveType: UInt32(t), indexType: UInt32(it), indexBuffer: ref(.resource, ib),
                                                              indexBufferOffset: off, indexCount: n)))
        case 7, 9:
            // Op 9 ends with u16 instance count and i16 base vertex (an
            // instance count of 0x12345 takes long form 8; RenderBox sends
            // base vertices 0x200, 0x300 here; metal-sim-protocol.md §8.3).
            let t = try r.u16(), it = try r.u16(), ib = try r.u32(), n = try r.int16(), off = try r.int16()
            let instances = rec.op == 9 ? try r.int16() : 1
            let baseVertex = rec.op == 9 ? Int(Int16(bitPattern: try r.u16())) : 0
            return checked(rec, .drawIndexed(MetalIndexedDraw(primitiveType: UInt32(t), indexType: UInt32(it), indexBuffer: ref(.resource, ib),
                                                              indexBufferOffset: off, indexCount: n, instanceCount: instances,
                                                              baseVertex: baseVertex)))
        case 28:
            // Long form of `…instanceCount:baseVertex:baseInstance:` (agent H's capture).
            let t = try r.u16(), it = try r.u16(), ib = try r.u32(), off = try r.int64(), n = try r.int64(), i = try r.int64()
            let bv = Int(Int64(bitPattern: try r.u64())), bi = try r.int64()
            return checked(rec, .drawIndexed(MetalIndexedDraw(primitiveType: UInt32(t), indexType: UInt32(it), indexBuffer: ref(.resource, ib),
                                                              indexBufferOffset: off, indexCount: n, instanceCount: i,
                                                              baseVertex: bv, baseInstance: bi)))
        case 29:
            // The short form: every value fits in 16 bits (larger ones take
            // op 28), the base instance too. Its last word holds the base
            // instance in the low half; the high half is not written by the
            // guest driver (visionOS backboardd sends 0x3FF0, 0x40A0, 0x40AE,
            // 0x24, 0x3 there with base instance 0: stale bytes; read as one
            // u32 they made base instances of a billion; visionos.md §9 Q24,
            // §10.20).
            let t = try r.u16(), it = try r.u16(), ib = try r.u32()
            let off = try r.int16(), n = try r.int16(), i = try r.int16(), bv = Int(Int16(bitPattern: try r.u16()))
            let word = try r.u32()
            if word >> 16 != 0 { noteShortBaseInstanceHigh(rec) }
            return .drawIndexed(MetalIndexedDraw(primitiveType: UInt32(t), indexType: UInt32(it), indexBuffer: ref(.resource, ib),
                                                 indexBufferOffset: off, indexCount: n, instanceCount: i, baseVertex: bv,
                                                 baseInstance: Int(word & 0xFFFF)))
        case 16:
            let off = try r.int64(), b = try r.u32(), t = try r.u32()
            return .drawIndirect(primitiveType: t, indirectBuffer: ref(.resource, b), indirectOffset: off)
        case 17:
            let t = try r.u16(), it = try r.u16(), ib = try r.u32(), indirect = try r.u32()
            let ibOff = try r.int64(), indOff = try r.int64()
            return .drawIndexedIndirect(primitiveType: UInt32(t), indexType: UInt32(it), indexBuffer: ref(.resource, ib),
                                        indexBufferOffset: ibOff, indirectBuffer: ref(.resource, indirect), indirectOffset: indOff)
        case 22:
            let n = try r.int32(), after = try r.u16(), before = try r.u16()
            return .memoryBarrierResources(try refs(&r, count: n, .resource), afterStages: after, beforeStages: before)
        case 23:
            let scope = try r.u16(), after = try r.u8(), before = try r.u8()
            return .memoryBarrier(scope: scope, afterStages: after, beforeStages: before)
        case 24, 25:
            // u32 fence ref, u32 MTLRenderStages (visionos.md §10.12.1).
            let f = try r.u32(), stages = try r.u32()
            return rec.op == 24 ? .updateFence(ref(.fence, f), stages: stages) : .waitForFence(ref(.fence, f), stages: stages)
        case 27:
            let n = try r.int32(), stages = try r.u16()
            return .useHeaps(try unalignedRefs(rec.body, at: 6, count: n, .heap), stages: stages)
        case 134:
            let n = try r.int32()
            return .useHeaps(try refs(&r, count: n, .heap), stages: nil)
        case 132:
            let offset = try r.int64(), mode = try r.u64()
            return .setVisibilityResultMode(mode, offset: offset)
        case 101:
            return .setBlendColor(red: try r.f32(), green: try r.f32(), blue: try r.f32(), alpha: try r.f32())
        case 102:
            // u32 action, then u32 index (VISIONOS-OBS4's probe).
            let action = try r.u32()
            return .setStoreAction(index: try r.int32(), action: action)
        case 103:
            let options = try r.u64()
            return .setStoreActionOptions(index: try r.int32(), options: options)
        case 105, 120:
            let action = UInt32(truncatingIfNeeded: try r.u64())
            return .setStoreAction(index: rec.op == 105 ? MetalRenderCommand.depthAttachment : MetalRenderCommand.stencilAttachment,
                                   action: action)
        case 106, 121:
            let options = try r.u64()
            return .setStoreActionOptions(index: rec.op == 106 ? MetalRenderCommand.depthAttachment : MetalRenderCommand.stencilAttachment,
                                          options: options)
        case 104:
            return .setDepthStencilState(ref(.depthStencil, try r.u32()))
        case 107: return .setCullMode(try r.u64())
        case 108: return .setDepthBias(depthBias: try r.f32(), slopeScale: try r.f32(), clamp: try r.f32())
        case 109: return .setDepthClipMode(try r.u64())
        case 110, 125:
            guard let index = try slot(&r) else { return nil }
            let b = try r.u32(), off = try r.int64()
            return .setBuffer(stage: rec.op == 125 ? .vertex : .fragment, index: index, buffer: ref(.resource, b), offset: off)
        case 111, 126:
            let index = try r.int32(), off = try r.int64()
            return .setBufferOffset(stage: rec.op == 126 ? .vertex : .fragment, index: index, offset: off)
        case 112, 113, 127:
            guard let index = try slot(&r) else { return nil }
            let s = try r.u32()
            var lo: Float?, hi: Float?
            if rec.op == 113 { lo = try r.f32(); hi = try r.f32() }
            return .setSamplerState(stage: rec.op == 127 ? .vertex : .fragment, index: index, sampler: ref(.sampler, s),
                                    lodMinClamp: lo, lodMaxClamp: hi)
        case 114, 129:
            guard let index = try slot(&r) else { return nil }
            return .setTexture(stage: rec.op == 129 ? .vertex : .fragment, index: index, texture: ref(.resource, try r.u32()))
        case 115: return .setFrontFacingWinding(try r.u64())
        case 116: return .setRenderPipelineState(ref(.renderPipeline, try r.u32()))
        case 117:
            return .setScissorRect(MetalScissorRect(x: try r.int64(), y: try r.int64(), width: try r.int64(), height: try r.int64()))
        case 119: return .setStencilReference(front: try r.u32(), back: try r.u32())
        case 124: return .setTriangleFillMode(try r.u64())
        case 130:
            return .setViewport(MetalViewport(x: try r.f64(), y: try r.f64(), width: try r.f64(), height: try r.f64(),
                                              znear: try r.f64(), zfar: try r.f64()))
        case 135:
            let n = try r.int32(), usage = try r.u32()
            return .useResources(try refs(&r, count: n, .resource), usage: usage, stages: nil)
        case 137:
            let n = try r.int32(), usage = try r.u16(), stages = try r.u16()
            return .useResources(try refs(&r, count: n, .resource), usage: UInt32(usage), stages: stages)
        default:
            return nil
        }
    }

    // MARK: Compute records (§8.4)

    func size3(_ r: inout ByteReader) throws -> MetalSize3 { MetalSize3(try r.int64(), try r.int64(), try r.int64()) }

    func computeCommand(_ rec: MetalRecord) -> MetalComputeCommand {
        var r = ByteReader(rec.body)
        let c: MetalComputeCommand? = try? {
            switch rec.op {
            case 200:
                let g = try size3(&r)
                return .dispatchThreadgroups(g, threadsPerThreadgroup: try size3(&r))
            case 201:
                let t = try size3(&r), off = try r.int64(), b = try r.u32()
                return .dispatchThreadgroupsIndirect(buffer: ref(.resource, b), offset: off, threadsPerThreadgroup: t)
            case 202:
                let g = try size3(&r)
                return .dispatchThreads(g, threadsPerThreadgroup: try size3(&r))
            case 203:
                guard let index = try slot(&r) else { return nil }
                let b = try r.u32()
                return .setBuffer(index: index, buffer: ref(.resource, b), offset: try r.int64())
            case 204, 205:
                guard let index = try slot(&r) else { return nil }
                let s = try r.u32()
                var lo: Float?, hi: Float?
                if rec.op == 205 { lo = try r.f32(); hi = try r.f32() }
                return .setSamplerState(index: index, sampler: ref(.sampler, s), lodMinClamp: lo, lodMaxClamp: hi)
            case 206:
                guard let index = try slot(&r) else { return nil }
                return .setTexture(index: index, texture: ref(.resource, try r.u32()))
            case 207:
                let index = try r.int32()
                return .setBufferOffset(index: index, offset: try r.int64())
            case 208: return .setComputePipelineState(ref(.computePipeline, try r.u32()))
            case 209:
                // Size first, then origin (VISIONOS-OBS4's probe, metal-sim-protocol.md §8.4).
                let size = try size3(&r)
                return .setStageInRegion(origin: try size3(&r), size: size)
            case 211:
                let length = try r.int64()
                return .setThreadgroupMemoryLength(length, index: try r.int32())
            case 214:
                let n = try r.int32()
                return .memoryBarrierResources(try refs(&r, count: n, .resource))
            case 215: return .memoryBarrier(scope: try r.u32())
            case 212: return .updateFence(ref(.fence, try r.u32()))
            case 213: return .waitForFence(ref(.fence, try r.u32()))
            case 134:
                let n = try r.int32()
                return .useHeaps(try refs(&r, count: n, .heap))
            case 135:
                let n = try r.int32(), usage = try r.u32()
                return .useResources(try refs(&r, count: n, .resource), usage: usage, stages: nil)
            case 137:
                let n = try r.int32(), usage = try r.u16(), stages = try r.u16()
                return .useResources(try refs(&r, count: n, .resource), usage: UInt32(usage), stages: stages)
            default: return nil
            }
        }()
        return c ?? .unknown(op: rec.op, body: rec.body)
    }

    // MARK: Blit records (§8.4)

    func blitCommand(_ rec: MetalRecord) -> MetalBlitCommand {
        var r = ByteReader(rec.body)
        let c: MetalBlitCommand? = try? {
            switch rec.op {
            case 300:
                let src = try r.u32(), dst = try r.u32(), srcOff = try r.int64(), bpr = try r.int64(), bpi = try r.int64()
                let size = try size3(&r), origin = try size3(&r)
                let slice = try r.int16(), level = try r.int16(), options = try r.u32()
                return .copyBufferToTexture(source: ref(.resource, src), sourceOffset: srcOff, bytesPerRow: bpr, bytesPerImage: bpi,
                                            size: size, destination: ref(.resource, dst), slice: slice, level: level, origin: origin,
                                            options: options)
            case 301:
                let src = try r.u32(), dst = try r.u32(), so = try r.int64(), dO = try r.int64(), n = try r.int64()
                return .copyBufferToBuffer(source: ref(.resource, src), sourceOffset: so, destination: ref(.resource, dst),
                                           destinationOffset: dO, size: n)
            case 302:
                let src = try r.u32(), dst = try r.u32(), origin = try size3(&r), size = try size3(&r)
                let dOff = try r.int64(), bpr = try r.int64(), bpi = try r.int64()
                let slice = try r.int16(), level = try r.int16(), options = try r.u32()
                return .copyTextureToBuffer(source: ref(.resource, src), slice: slice, level: level, origin: origin, size: size,
                                            destination: ref(.resource, dst), destinationOffset: dOff, bytesPerRow: bpr,
                                            bytesPerImage: bpi, options: options)
            case 303:
                let src = try r.u32(), dst = try r.u32(), so = try size3(&r), size = try size3(&r), dO = try size3(&r)
                let ss = try r.int16(), sl = try r.int16(), ds = try r.int16(), dl = try r.int16()
                return .copyTextureToTexture(source: ref(.resource, src), sourceSlice: ss, sourceLevel: sl, sourceOrigin: so,
                                             size: size, destination: ref(.resource, dst), destinationSlice: ds,
                                             destinationLevel: dl, destinationOrigin: dO)
            case 306:
                let b = try r.u32(), loc = try r.int64(), n = try r.int64(), v = try r.u32()
                return .fillBuffer(ref(.resource, b), location: loc, length: n, value: v)
            case 307: return .generateMipmaps(ref(.resource, try r.u32()))
            case 309: return .optimizeContentsForGPUAccess(ref(.resource, try r.u32()))
            case 316: return .updateFence(ref(.fence, try r.u32()))
            case 317: return .waitForFence(ref(.fence, try r.u32()))
            case 318:
                let src = try r.u32(), dst = try r.u32()
                let ss = try r.int16(), sl = try r.int16(), ds = try r.int16(), dl = try r.int16()
                let sc = try r.int16(), lc = try r.int16()
                return .copyTextureSlices(source: ref(.resource, src), sourceSlice: ss, sourceLevel: sl,
                                          destination: ref(.resource, dst), destinationSlice: ds, destinationLevel: dl,
                                          sliceCount: sc, levelCount: lc)
            default: return nil
            }
        }()
        return c ?? .unknown(op: rec.op, body: rec.body)
    }

    // MARK: Event records (§8.4)

    func eventCommand(_ rec: MetalRecord) -> MetalEventCommand {
        var r = ByteReader(rec.body)
        guard rec.op == 400 || rec.op == 401, let e = try? r.u32(), let v = try? r.u64() else {
            return .unknown(op: rec.op, body: rec.body)
        }
        return rec.op == 400 ? .wait(ref(.event, e), value: v) : .signal(ref(.event, e), value: v)
    }
}
