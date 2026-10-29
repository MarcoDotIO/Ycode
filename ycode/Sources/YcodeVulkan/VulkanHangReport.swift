// GPU hang and device-loss reports (diagnostics; stage8-contract.md §15).
//
// A submission that runs longer than `Options.hangReportSeconds` is logged
// once with a description of its Metal command buffer: every pass with its
// attachments and every draw, dispatch and blit with its pipeline, counts
// and bound resources. On device loss the back end logs the same for the
// submissions still pending and, when the device has
// VK_NV_device_diagnostic_checkpoints (`YCODE_GPU_CHECKPOINTS=0` turns it
// off), the last checkpoint markers the queue passed at the top and bottom
// of the pipe: which command of which command buffer was running.
//
// Markers: (recording id << 32) | (pass << 20) | command. Pass 4095 is the
// prologue (IOSurface copy-ins, command 0) and epilogue (copy-outs, command
// 1); command 0xFFFFF is the pass's begin; command | 0x80000 is the point
// after a dispatch and the barrier that follows it (the dispatch finished).
// The markers are also read while a submission runs (the reports at 2 s and
// every 10 s): NVIDIA's driver answers the query before a device loss too.

import CVulkan
import Foundation
import YcodeMetalHost

/// A recorded command buffer the checkpoint markers can name.
struct CheckpointRecord {
    var id: UInt32
    var process: MetalProcessID
    var commandBufferRef: UInt64
    var commandBuffer: MetalCommandBuffer?
}

extension VulkanMetalBackend {
    static let checkpointPrologue = 4095
    static let checkpointPassBegin = 0xFFFFF
    static let checkpointAfter = 0x80000

    var checkpointsOn: Bool { ctx.pointee.features.diagnosticCheckpoints != 0 }

    /// A checkpoint marker in `rec` (nothing without the extension).
    func checkpoint(_ rec: Recording, pass: Int, command: Int) {
        guard checkpointsOn else { return }
        let marker = UInt64(rec.checkpointID) << 32 | UInt64(min(pass, 4095)) << 20 | UInt64(min(command, 0xFFFFF))
        yvk_cmd_checkpoint(rec.cb, marker)
    }

    /// Notes which command buffer a recording's markers belong to. Under the lock.
    func registerCheckpoints(_ rec: Recording, _ mcb: MetalCommandBuffer) {
        guard checkpointsOn else { return }
        checkpointRecords.append(CheckpointRecord(id: rec.checkpointID, process: mcb.process,
                                                  commandBufferRef: mcb.commandBufferRef, commandBuffer: mcb))
        if checkpointRecords.count > 128 { checkpointRecords.removeFirst(checkpointRecords.count - 128) }
    }

    /// What a marker points at. Under the lock.
    func describeMarker(_ marker: UInt64) -> String {
        let id = UInt32(truncatingIfNeeded: marker >> 32)
        let pass = Int((marker >> 20) & 0xFFF), command = Int(marker & 0xFFFFF)
        let where_: String
        if pass == Self.checkpointPrologue {
            where_ = command == 0 ? "IOSurface copy-ins" : "IOSurface copy-outs"
        } else if command == Self.checkpointPassBegin {
            where_ = "pass \(pass) begin"
        } else if command & Self.checkpointAfter != 0 {
            where_ = "pass \(pass) after command \(command & ~Self.checkpointAfter)"
        } else {
            where_ = "pass \(pass) command \(command)"
        }
        guard let r = checkpointRecords.last(where: { $0.id == id }) else { return "recording \(id) (unknown): \(where_)" }
        var text = "process \(r.process) command buffer \(r.commandBufferRef) (recording \(id)): \(where_)"
        if pass != Self.checkpointPrologue, command != Self.checkpointPassBegin, let mcb = r.commandBuffer,
           pass < mcb.passes.count {
            text += " = " + describeCommand(mcb.passes[pass], command & ~Self.checkpointAfter)
        }
        return text
    }

    /// One command of a pass, for a marker.
    func describeCommand(_ pass: MetalPass, _ index: Int) -> String {
        switch pass {
        case .render(let p):
            guard index < p.commands.count else { return "?" }
            // The render pipeline and fragment textures in effect at the command.
            var pipeline: MetalHandle?
            var ft: [Int: MetalHandle?] = [:]
            for c in p.commands[..<index] {
                switch c {
                case .setRenderPipelineState(let h): pipeline = h
                case .setTexture(let s, let i, let t) where s != .vertex: ft[i] = t
                default: break
                }
            }
            let textures = ft.sorted { $0.key < $1.key }.map { "ft\($0.key)=\(describeTexture($0.value))" }.joined(separator: ", ")
            return "\(p.commands[index]) with \(describePipeline(pipeline)) [\(textures)]"
        case .compute(let c): return index < c.count ? "\(c[index])" : "?"
        case .blit(let c): return index < c.count ? "\(c[index])" : "?"
        default: return "?"
        }
    }

    // MARK: Command-buffer descriptions

    func describeTexture(_ h: MetalHandle?) -> String {
        guard let h else { return "nil" }
        guard let t = textures[h] else { return "t\(h.raw)?" }
        let (w, hh, d) = t.levelSize(0)
        var s = "t\(h.raw) \(w)x\(hh)" + (d > 1 ? "x\(d)" : "") + " fmt \(t.metalFormat)"
        if t.image.samples > 1 { s += " ×\(t.image.samples)" }
        if t.levelCount > 1 { s += " mips \(t.levelCount)" }
        if let surface = t.image.surface { s += " surface \(surface.surfaceID)" }
        return s
    }

    func describeBuffer(_ h: MetalHandle?, _ offset: Int) -> String {
        guard let h else { return "nil" }
        guard let b = buffers[h] else { return "b\(h.raw)?" }
        return "b\(h.raw) \(b.length) B" + (offset != 0 ? " @\(offset)" : "") + (b.storage == .private ? " private" : "")
    }

    func describePipeline(_ h: MetalHandle?) -> String {
        guard let h else { return "no pipeline" }
        guard let p = renderPipelines[h] else { return "pipeline \(h.raw)?" }
        var s = "\(shaderName(p.vertex))+\(shaderName(p.fragment))"
        if p.broken { s += " (broken)" }
        if !p.isBuilt { s += " (not built)" }
        return s
    }

    /// A description of a command buffer for a hang report (at most
    /// `limit` commands with work). Under the lock.
    func describeCommandBuffer(_ mcb: MetalCommandBuffer, limit: Int = 240) -> String {
        var lines: [String] = []
        var budget = limit
        for (pi, pass) in mcb.passes.enumerated() {
            switch pass {
            case .render(let p):
                var head = "pass \(pi) render"
                var passSamples = 1
                if let d = p.descriptor {
                    for t in d.colorAttachments.map({ $0.texture }) + [d.depth?.texture, d.stencil?.texture] {
                        if let t, let tex = textures[t] { passSamples = max(passSamples, tex.image.samples) }
                    }
                    for c in d.colorAttachments {
                        head += " c\(c.index)[\(describeTexture(c.texture)) load \(c.attachment.loadAction) store \(c.attachment.storeAction)"
                            + (c.resolveTexture != nil ? " resolve \(describeTexture(c.resolveTexture))" : "") + "]"
                    }
                    if let a = d.depth { head += " depth[\(describeTexture(a.texture)) load \(a.loadAction)]" }
                    if let a = d.stencil { head += " stencil[\(describeTexture(a.texture)) load \(a.loadAction)]" }
                    head += " target \(d.renderTargetWidth)x\(d.renderTargetHeight)"
                } else {
                    head += " (no descriptor)"
                }
                lines.append(head)
                var pipeline: MetalHandle?
                var vb: [Int: (MetalHandle?, Int)] = [:], fb: [Int: (MetalHandle?, Int)] = [:]
                var vt: [Int: MetalHandle?] = [:], ft: [Int: MetalHandle?] = [:]
                var viewport = "", scissor = ""
                func pointerChecks() -> String {
                    let bound = vb.map { ("v\($0.key)", $0.value.0, $0.value.1) } + fb.map { ("f\($0.key)", $0.value.0, $0.value.1) }
                    let t = describeDanglingPointers(bound)
                    return t.isEmpty ? "" : " {\(t)}"
                }
                func bindings() -> String {
                    let b = vb.sorted { $0.key < $1.key }.map { "v\($0.key)=\(describeBuffer($0.value.0, $0.value.1))" }
                        + fb.sorted { $0.key < $1.key }.map { "f\($0.key)=\(describeBuffer($0.value.0, $0.value.1))" }
                        + vt.sorted { $0.key < $1.key }.map { "vt\($0.key)=\(describeTexture($0.value))" }
                        + ft.sorted { $0.key < $1.key }.map { "ft\($0.key)=\(describeTexture($0.value))" }
                    return b.joined(separator: ", ")
                }
                for (ci, c) in p.commands.enumerated() {
                    switch c {
                    case .setRenderPipelineState(let h): pipeline = h
                    case .setBuffer(let s, let i, let b, let o): if s == .vertex { vb[i] = (b, o) } else { fb[i] = (b, o) }
                    case .setBufferOffset(let s, let i, let o):
                        if s == .vertex { vb[i] = (vb[i]?.0, o) } else { fb[i] = (fb[i]?.0, o) }
                    case .setTexture(let s, let i, let t): if s == .vertex { vt[i] = t } else { ft[i] = t }
                    case .setViewport(let v): viewport = String(format: " vp %.0f,%.0f %.0fx%.0f", v.x, v.y, v.width, v.height)
                    case .setScissorRect(let r): scissor = " sc \(r.x),\(r.y) \(r.width)x\(r.height)"
                    case .draw(let d):
                        guard budget > 0 else { continue }
                        budget -= 1
                        lines.append("  \(ci): draw \(describePipeline(pipeline)) prim \(d.primitiveType) start \(d.vertexStart) count \(d.vertexCount) "
                                     + "instances \(d.instanceCount) base \(d.baseInstance)\(viewport)\(scissor) [\(bindings())] {"
                                     + describeDrawChecks(pipeline, passSamples: passSamples, vertexBuffers: vb, firstVertex: d.vertexStart,
                                                          vertexCount: d.vertexCount, instances: (d.baseInstance, d.instanceCount), indexed: nil) + "}" + pointerChecks())
                    case .drawIndexed(let d):
                        guard budget > 0 else { continue }
                        budget -= 1
                        lines.append("  \(ci): drawIndexed \(describePipeline(pipeline)) prim \(d.primitiveType) indices \(d.indexCount) "
                                     + "type \(d.indexType) ib \(describeBuffer(d.indexBuffer, d.indexBufferOffset)) instances \(d.instanceCount) "
                                     + "baseVertex \(d.baseVertex) baseInstance \(d.baseInstance)\(viewport)\(scissor) [\(bindings())] {"
                                     + describeDrawChecks(pipeline, passSamples: passSamples, vertexBuffers: vb, firstVertex: 0,
                                                          vertexCount: 0, instances: (d.baseInstance, d.instanceCount), indexed: d) + "}" + pointerChecks())
                    case .drawIndirect(let prim, let ib, let off):
                        guard budget > 0 else { continue }
                        budget -= 1
                        lines.append("  \(ci): drawIndirect \(describePipeline(pipeline)) prim \(prim) args \(describeBuffer(ib, off))"
                                     + "\(indirectArguments(ib, off, words: 4))\(viewport)\(scissor) [\(bindings())]")
                    case .drawIndexedIndirect(let prim, let type, let ixb, let ixo, let ib, let off):
                        guard budget > 0 else { continue }
                        budget -= 1
                        lines.append("  \(ci): drawIndexedIndirect \(describePipeline(pipeline)) prim \(prim) type \(type) ib "
                                     + "\(describeBuffer(ixb, ixo)) args \(describeBuffer(ib, off))\(indirectArguments(ib, off, words: 5))"
                                     + "\(viewport)\(scissor) [\(bindings())]")
                    default: break
                    }
                }
            case .compute(let cmds):
                lines.append("pass \(pi) compute")
                var pipeline: MetalHandle?
                var b: [Int: (MetalHandle?, Int)] = [:]
                var t: [Int: MetalHandle?] = [:]
                for (ci, c) in cmds.enumerated() {
                    switch c {
                    case .setComputePipelineState(let h): pipeline = h
                    case .setBuffer(let i, let h, let o): b[i] = (h, o)
                    case .setBufferOffset(let i, let o): b[i] = (b[i]?.0, o)
                    case .setTexture(let i, let h): t[i] = h
                    case .dispatchThreadgroups, .dispatchThreads, .dispatchThreadgroupsIndirect:
                        guard budget > 0 else { continue }
                        budget -= 1
                        let name = pipeline.flatMap { computePipelines[$0] }.map { shaderName($0.shader) } ?? "no pipeline"
                        let res = b.sorted { $0.key < $1.key }.map { "b\($0.key)=\(describeBuffer($0.value.0, $0.value.1))" }
                            + t.sorted { $0.key < $1.key }.map { "t\($0.key)=\(describeTexture($0.value))" }
                        lines.append("  \(ci): \(c) \(name) [\(res.joined(separator: ", "))]")
                    default: break
                    }
                }
            case .blit(let cmds):
                lines.append("pass \(pi) blit")
                for (ci, c) in cmds.enumerated() where budget > 0 {
                    budget -= 1
                    switch c {
                    case .copyBufferToTexture(let s, let so, let bpr, _, let size, let d, let slice, let level, let origin, _):
                        lines.append("  \(ci): buffer \(describeBuffer(s, so)) row \(bpr) → \(describeTexture(d)) level \(level) slice \(slice) "
                                     + "at \(origin.width),\(origin.height) size \(size.width)x\(size.height)x\(size.depth)")
                    default:
                        lines.append("  \(ci): \(c)")
                    }
                }
            case .event(let cmds):
                lines.append("pass \(pi) events \(cmds)")
            case .unknown(let kind, let records):
                lines.append("pass \(pi) unknown kind \(kind), \(records.count) records")
            }
        }
        if budget <= 0 { lines.append("(more commands not listed)") }
        return lines.joined(separator: "\n    ")
    }

    /// `YCODE_GPU_SKIP_SHADERS`: whether a draw with `p` is skipped (experiments).
    func skippedByName(_ p: VKRenderPipeline) -> Bool {
        for s in [p.vertex, p.fragment] {
            guard let s else { continue }
            if options.skipShaders.contains(shaderName(s)) || options.skipShaders.contains(s.reflection.entryPoint ?? "") { return true }
        }
        return false
    }

    /// Checks of one draw for a hang report: the pipeline's sample count
    /// against the pass's, the stage built-ins that select a viewport or a
    /// layer, the range of indices the CPU can read now, and whether the
    /// highest vertex fits each Vulkan vertex buffer. Under the lock.
    func describeDrawChecks(_ pipeline: MetalHandle?, passSamples: Int, vertexBuffers vb: [Int: (MetalHandle?, Int)],
                            firstVertex: Int, vertexCount: Int, instances: (base: Int, count: Int),
                            indexed: (MetalIndexedDraw)?) -> String {
        guard let h = pipeline, let p = renderPipelines[h] else { return "" }
        var notes: [String] = []
        let ps = Int(p.info.samples.rawValue)
        notes.append(ps == passSamples ? "samples \(ps)" : "SAMPLES pipeline \(ps) pass \(passSamples)")
        let vsOut = p.vertex?.reflection.builtins ?? []
        for b in ["viewport_array_index", "render_target_array_index", "clip_distance", "amplification_id", "instance_id", "base_instance"] where vsOut.contains(b) {
            notes.append("vs \(b)")
        }
        // The vertices the draw reaches.
        var lo = firstVertex, hi = firstVertex + vertexCount - 1
        if let d = indexed {
            let size = d.indexType == MetalIndexType.uint32 ? 4 : 2
            if let ib = d.indexBuffer, let b = buffers[ib], let ptr = b.hostPointer,
               d.indexBufferOffset >= 0, d.indexBufferOffset + d.indexCount * size <= b.length, d.indexCount > 0 {
                var mn = Int.max, mx = Int.min
                for i in 0..<d.indexCount {
                    let v = size == 4 ? Int(ptr.load(fromByteOffset: d.indexBufferOffset + 4 * i, as: UInt32.self))
                                      : Int(ptr.load(fromByteOffset: d.indexBufferOffset + 2 * i, as: UInt16.self))
                    mn = min(mn, v); mx = max(mx, v)
                }
                lo = mn + d.baseVertex; hi = mx + d.baseVertex
                notes.append("indices now \(mn)...\(mx)")
            } else {
                notes.append("indices unreadable")
                return notes.joined(separator: ", ")
            }
        }
        if let vd = p.desc.vertexDescriptor {
            for idx in p.vertexBufferIndices {
                let l = vd.layouts.first { $0.bufferIndex == idx }
                // Step function 0 constant, 1 per vertex, 2 per instance.
                guard let l, l.stepFunction != 0 else { continue }
                var lo = lo, hi = hi
                if l.stepFunction == 2 {
                    let rate = max(l.stepRate, 1)
                    lo = instances.base / rate; hi = (instances.base + instances.count - 1) / rate
                }
                let end = vd.attributes.filter { $0.format != 0 && $0.bufferIndex == idx }.map { $0.offset + 1 }.max() ?? 1
                guard let bh = vb[idx]?.0, let b = buffers[bh], l.stride > 0 else {
                    notes.append("vb\(idx) unbound"); continue
                }
                let room = b.length - (vb[idx]?.1 ?? 0) - end
                let capacity = room < 0 ? 0 : room / l.stride + 1
                let unit = l.stepFunction == 2 ? "instances" : "vertices"
                notes.append(hi < capacity && lo >= 0 ? "vb\(idx)\(l.stepFunction == 2 ? "/i" : "") stride \(l.stride) fits \(capacity)"
                             : "VB\(idx) stride \(l.stride) holds \(capacity) \(unit), draw reaches \(lo)...\(hi)")
            }
        }
        return notes.joined(separator: ", ")
    }

    /// Pointer check of a hang report: every aligned 8-byte word of the
    /// buffers a draw binds (and, one level down, of the buffers those words
    /// point into) that looks like a device address of this back end (within
    /// 1 GiB of the live buffers' range) is looked up among the live buffers.
    /// A word that points into none is a dangling address: a shader that
    /// reads through it reads unmapped memory, which stalls the Thor's GPU
    /// (stage8-contract.md §15.6). Under the lock.
    func describeDanglingPointers(_ bound: [(String, MetalHandle?, Int)]) -> String {
        var ranges: [(UInt64, UInt64, MetalHandle)] = []
        for (h, b) in buffers where b.length > 0 { ranges.append((b.address, b.address + UInt64(b.length), h)) }
        guard !ranges.isEmpty else { return "" }
        ranges.sort { $0.0 < $1.0 }
        let lo = ranges.first!.0, hi = (ranges.map { $0.1 }.max() ?? 0) &+ (64 << 20)
        func owner(_ v: UInt64) -> (UInt64, UInt64, MetalHandle)? {
            var a = 0, b = ranges.count
            while a < b { let m = (a + b) / 2; if ranges[m].0 <= v { a = m + 1 } else { b = m } }
            var i = a - 1
            while i >= 0 && i >= a - 64 { if v >= ranges[i].0 && v < ranges[i].1 { return ranges[i] }; i -= 1 }
            return nil
        }
        var notes: [String] = []
        var seen: Set<MetalHandle> = []
        var queue: [(String, MetalHandle, Int, Int)] = bound.compactMap { n, h, o in h.map { (n, $0, o, 0) } }
        var dangling = 0, pointers = 0, unknown = 0
        var released: [UInt64: UInt64] = [:]
        for r in releasedBufferRanges { released[r.0] = r.2 }
        while let (name, h, from, depth) = queue.first {
            queue.removeFirst()
            guard seen.insert(h).inserted, let b = buffers[h], let p = b.hostPointer else { continue }
            let start = max(0, from) & ~7, end = min(b.length, start + (1 << 20)) & ~7
            var i = start
            while i + 8 <= end {
                let v = p.load(fromByteOffset: i, as: UInt64.self)
                // Candidates: inside the live buffers' range and 16-byte
                // aligned, or a released buffer's address, or Ycode's
                // synthetic address range (MetalHostCore's addresses for
                // buffers the back end does not know). Float data falls in
                // the live range too, so only exact released or synthetic
                // matches and live hits count for certain.
                let synthetic = v >= 0x100_0000_0000 && v < 0x200_0000_0000
                if synthetic || (v >= lo && v < hi && v & 3 == 0) {
                    if let o = owner(v) {
                        pointers += 1
                        if pointers <= 4 { notes.append("\(name) b\(h.raw)+\(i) → b\(o.2.raw)+\(v - o.0)") }
                        if depth == 0 { queue.append(("\(name)→b\(o.2.raw)", o.2, Int(v - o.0), 1)) }
                    } else if synthetic || released[v] != nil {
                        dangling += 1
                        if dangling <= 6 {
                            let why = synthetic ? "synthetic address" : "start of released b\(released[v]!)"
                            notes.append("\(name) b\(h.raw)+\(i) = 0x\(String(v, radix: 16)) (\(why))")
                        }
                    } else if v & 0xFFFF == 0 {
                        unknown += 1
                        if unknown <= 4 { notes.append("\(name) b\(h.raw)+\(i) = 0x\(String(v, radix: 16)) (64 KiB-aligned, no buffer)") }
                    }
                }
                i += 8
            }
        }
        guard pointers + dangling + unknown > 0 else { return "" }
        return "pointers \(pointers), released or synthetic \(dangling), unowned aligned \(unknown)"
            + (notes.isEmpty ? "" : ": " + notes.joined(separator: "; "))
    }

    /// The first words of an indirect-arguments buffer when the CPU can read it.
    func indirectArguments(_ h: MetalHandle?, _ offset: Int, words: Int) -> String {
        guard let h, let b = buffers[h], let p = b.hostPointer, offset >= 0, offset + 4 * words <= b.length else { return "" }
        let values = (0..<words).map { p.load(fromByteOffset: offset + 4 * $0, as: UInt32.self) }
        return " (now " + values.map(String.init).joined(separator: " ") + ")"
    }

    // MARK: Reports

    /// Logs the description of the oldest pending submission (a hang). Under the lock.
    func reportRunningSubmission(serial: UInt64, seconds: Double) {
        guard let e = pending.first(where: { $0.serial == serial }) ?? pending.first else { return }
        var text = String(format: "serial %llu has run for %.1f s: ", serial, seconds) + e.label
        if let mcb = e.commandBuffer {
            let description = describeCommandBuffer(mcb)
            text += "\n    " + description
            if let dir = Self.hangCaptureDirectory { text += "\n    capture: " + capture(mcb, description: description, into: dir, serial: serial) }
        }
        if !e.dispatchTables.isEmpty { text += "\n    dispatch tables:" + describeDispatchTables(e.dispatchTables) }
        text += currentCheckpoints()
        log(text)
    }

    /// The argument tables of a pending submission's dispatches as the GPU
    /// reads them: each non-zero buffer entry (0–30) and the constant data
    /// (31) resolved to the live buffer, pipeline constant data or the dummy
    /// buffer it points into, or "NOT LIVE" when it points into none (a read
    /// there reaches unmapped memory, which stalls the Thor's GPU,
    /// stage8-contract.md §15.6); texture entries (32–159) resolved to the
    /// live texture with that heap index. Under the lock.
    func describeDispatchTables(_ tables: [(pass: Int, command: Int, table: UnsafeMutableRawPointer)]) -> String {
        var ranges: [(UInt64, UInt64, String)] = []
        for (h, b) in buffers { ranges.append((b.address, b.address + UInt64(max(b.length, 1)), "b\(h.raw)")) }
        for (h, p) in computePipelines {
            for a in p.statics.memory { ranges.append((a.buffer.address, a.buffer.address + a.buffer.size, "constants of c\(h.raw)")) }
        }
        for (h, p) in renderPipelines {
            for a in p.vertexStatics.memory + p.fragmentStatics.memory {
                ranges.append((a.buffer.address, a.buffer.address + a.buffer.size, "constants of p\(h.raw)"))
            }
        }
        ranges.append((dummyBufferAddress, dummyBufferAddress + dummyBuffer.size, "dummy"))
        var heap: [UInt32: String] = [:]
        for (h, t) in textures where t.heapIndex != 0 {
            let (w, hh, _) = t.levelSize(0)
            let name = "t\(h.raw) \(w)x\(hh) level \(t.baseLevel)" + (t.storageView == nil ? " (no storage view)" : "")
                + (t.heapIndex >= ctx.pointee.heapStorageImages ? " (index past the storage array)" : "")
            // Two live textures with one index: the later descriptor write won.
            heap[t.heapIndex] = heap[t.heapIndex].map { "SHARED by \($0) and \(name)" } ?? name
        }
        func resolve(_ v: UInt64) -> String {
            for r in ranges where v >= r.0 && v < r.1 { return r.2 + (v == r.0 ? "" : "+\(v - r.0)") }
            return "0x\(String(v, radix: 16)) NOT LIVE"
        }
        var text = ""
        for (n, t) in tables.prefix(24).enumerated() {
            var parts: [String] = []
            for entry in 0..<YcodeMetalABI.tableEntries {
                let v = t.table.load(fromByteOffset: 8 * entry, as: UInt64.self)
                guard v != 0 else { continue }
                if entry < 31 || entry == YcodeMetalABI.constantDataEntry {
                    parts.append("e\(entry)=\(resolve(v))")
                } else if entry >= YcodeMetalABI.textureEntry0 && entry < YcodeMetalABI.textureEntry0 + 128 {
                    parts.append("e\(entry)=heap \(v) \(heap[UInt32(truncatingIfNeeded: v)] ?? "NOT LIVE")")
                }
                if parts.count >= 12 { break }
            }
            text += "\n      \(n): pass \(t.pass) command \(t.command): " + parts.joined(separator: ", ")
        }
        return text
    }

    /// The last markers the queue passed at the top and bottom of the pipe,
    /// one line each (empty without the extension or an answer). Under the lock.
    func currentCheckpoints() -> String {
        guard checkpointsOn else { return "" }
        var markers = [UInt64](repeating: 0, count: 16), stages = [UInt64](repeating: 0, count: 16)
        let n = Int(yvk_queue_checkpoints(ctx, &markers, &stages, 16))
        var text = ""
        for i in 0..<n {
            let stage = stages[i] == VK_PIPELINE_STAGE_2_TOP_OF_PIPE_BIT ? "top of pipe"
                : stages[i] == VK_PIPELINE_STAGE_2_BOTTOM_OF_PIPE_BIT ? "bottom of pipe" : "stage 0x\(String(stages[i], radix: 16))"
            text += "\n  checkpoint (\(stage)): " + describeMarker(markers[i])
        }
        return text
    }

    /// `YCODE_GPU_HANG_CAPTURE=<dir>`: a hang report also saves the command
    /// buffer's translated shaders (SPIR-V and reflection) and the bytes of
    /// the buffers it binds that the CPU can read, for offline replay.
    static let hangCaptureDirectory = ProcessInfo.processInfo.environment["YCODE_GPU_HANG_CAPTURE"].flatMap { $0.isEmpty ? nil : $0 }

    /// Writes the capture; returns its directory or why it failed. Under the lock.
    func capture(_ mcb: MetalCommandBuffer, description: String, into root: String, serial: UInt64) -> String {
        let dir = "\(root)/hang-\(getpid())-\(serial)"
        let fm = FileManager.default
        do {
            try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try Data(description.utf8).write(to: URL(fileURLWithPath: dir + "/commands.txt"))
            var shaders: [String: TranslatedShader] = [:]
            var bufferHandles: Set<MetalHandle> = []
            for pass in mcb.passes {
                switch pass {
                case .render(let p):
                    for c in p.commands {
                        switch c {
                        case .setRenderPipelineState(let h?):
                            if let rp = renderPipelines[h] {
                                if let v = rp.vertex { shaders["p\(h.raw)-vertex"] = v }
                                if let f = rp.fragment { shaders["p\(h.raw)-fragment"] = f }
                            }
                        case .setBuffer(_, _, let b?, _): bufferHandles.insert(b)
                        case .drawIndexed(let d): if let b = d.indexBuffer { bufferHandles.insert(b) }
                        case .drawIndirect(_, let b?, _): bufferHandles.insert(b)
                        case .drawIndexedIndirect(_, _, let i, _, let b, _):
                            if let i { bufferHandles.insert(i) }
                            if let b { bufferHandles.insert(b) }
                        default: break
                        }
                    }
                case .compute(let cmds):
                    for c in cmds {
                        switch c {
                        case .setComputePipelineState(let h?): if let s = computePipelines[h]?.shader { shaders["c\(h.raw)-kernel"] = s }
                        case .setBuffer(_, let b?, _): bufferHandles.insert(b)
                        case .dispatchThreadgroupsIndirect(let b?, _, _): bufferHandles.insert(b)
                        default: break
                        }
                    }
                case .blit(let cmds):
                    for case .copyBufferToTexture(let s?, _, _, _, _, _, _, _, _, _) in cmds { bufferHandles.insert(s) }
                default: break
                }
            }
            let encoder = JSONEncoder()
            encoder.keyEncodingStrategy = .convertToSnakeCase
            for (name, s) in shaders {
                try s.spirv.withUnsafeBytes { try Data($0).write(to: URL(fileURLWithPath: "\(dir)/\(name).spv")) }
                try encoder.encode(s.reflection).write(to: URL(fileURLWithPath: "\(dir)/\(name).json"))
            }
            var budget = 256 << 20
            for h in bufferHandles {
                guard let b = buffers[h], let p = b.hostPointer, b.length > 0, b.length <= budget else { continue }
                budget -= b.length
                try Data(bytes: p, count: b.length).write(to: URL(fileURLWithPath: "\(dir)/b\(h.raw).bin"))
            }
            return dir
        } catch {
            return "failed (\(error))"
        }
    }

    /// Logs what was pending and running when the device was lost (once). Under the lock.
    func reportDeviceLoss(_ context: String) {
        guard !deviceLossReported else { return }
        deviceLossReported = true
        let now = DispatchTime.now().uptimeNanoseconds
        var text = "device lost (\(context)); serials \(completedSerial)/\(lastSubmitted), \(pending.count) pending"
        for e in pending.prefix(4) {
            text += String(format: "\n  serial %llu queued %.2f s ago: ", e.serial, Double(now &- e.queuedAt) / 1e9) + e.label
            if let mcb = e.commandBuffer { text += "\n    " + describeCommandBuffer(mcb, limit: 24) }
            if !e.dispatchTables.isEmpty { text += "\n    dispatch tables:" + describeDispatchTables(e.dispatchTables) }
        }
        if checkpointsOn {
            let c = currentCheckpoints()
            text += c.isEmpty ? "\n  checkpoints: none reported" : c
        }
        log(text)
    }
}
