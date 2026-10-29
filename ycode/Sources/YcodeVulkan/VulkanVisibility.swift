// Metal visibility results (`setVisibilityResultMode:offset:`, record 132,
// and the render pass descriptor's visibility result buffer) on Vulkan
// occlusion queries (visionos.md §10.20.8).
//
// While a pass's mode is boolean (1) or counting (2), its draws count the
// samples that pass the depth and stencil tests into the 8-byte slot at the
// mode's offset of the visibility result buffer; the slots are written when
// the pass ends. Here every run of draws with one mode and offset (a
// segment) is one occlusion query; after the pass the query results are
// copied into the buffer as 64-bit values. A query cannot stay active across
// the end of a dynamic rendering instance, so a feedback snapshot (which
// ends and restarts rendering) also ends a segment. Slots the pass does not
// use keep their bytes.

import CVulkan
import Foundation
import YcodeMetalHost

/// The occlusion queries of one render pass.
struct VisibilityQueries {
    let pool: VkQueryPool
    let first: UInt32
    let capacity: UInt32
    let buffer: VKBuffer
    let bufferHandle: MetalHandle
    let precise: Bool
    var mode: UInt64 = 0
    var offset = 0
    var used: UInt32 = 0
    var active = false
    /// (query, slot offset) per segment, in order.
    var segments: [(query: UInt32, offset: Int)] = []
}

extension VulkanMetalBackend {
    static let visibilityPoolSize = 1024

    /// Diagnostics: the first visibility-result modes and passes are logged.
    nonisolated(unsafe) static var visibilityLogged = 0

    /// Queries for a render pass that sets a non-zero visibility mode and has
    /// a visibility result buffer: `count` of them, reset in `rec`'s command
    /// buffer (outside rendering). Nil when the pass needs none.
    func visibilityQueries(_ pass: MetalRenderPass, _ rec: Recording) -> VisibilityQueries? {
        guard let d = pass.descriptor, pass.commands.contains(where: {
            if case .setVisibilityResultMode(let m, _) = $0 { return m != 0 }
            return false
        }) else { return nil }
        guard let vh = d.visibilityResultBuffer, let vb = buffers[vh] else {
            noteVisibility("visibility: a pass sets a visibility mode without a visibility result buffer; not counted")
            return nil
        }
        // At most one segment begins per draw.
        let count = pass.commands.count
        guard count <= Self.visibilityPoolSize else {
            noteVisibility("visibility: a pass of \(count) commands is beyond the query pool (\(Self.visibilityPoolSize)); not counted")
            return nil
        }
        if rec.visibilityPool == nil || rec.visibilityUsed + count > Self.visibilityPoolSize {
            guard let p = freeVisibilityPools.popLast() ?? makeVisibilityPool() else { return nil }
            rec.visibilityPool = p
            rec.visibilityPools.append(p)
            rec.visibilityUsed = 0
        }
        guard let pool = rec.visibilityPool else { return nil }
        let first = UInt32(rec.visibilityUsed)
        rec.visibilityUsed += count
        fn.vkCmdResetQueryPool!(rec.cb, pool, first, UInt32(count))
        statistics.visibilityPasses += 1
        return VisibilityQueries(pool: pool, first: first, capacity: UInt32(count), buffer: vb, bufferHandle: vh,
                                 precise: ctx.pointee.features.occlusionQueryPrecise != 0)
    }

    func makeVisibilityPool() -> VkQueryPool? {
        var ci = VkQueryPoolCreateInfo(sType: VK_STRUCTURE_TYPE_QUERY_POOL_CREATE_INFO, pNext: nil, flags: 0,
                                       queryType: VK_QUERY_TYPE_OCCLUSION, queryCount: UInt32(Self.visibilityPoolSize),
                                       pipelineStatistics: 0)
        var p: VkQueryPool?
        guard fn.vkCreateQueryPool!(device, &ci, nil, &p) == VK_SUCCESS, let p else {
            noteVisibility("visibility: vkCreateQueryPool failed; not counted")
            return nil
        }
        return p
    }

    /// A submitted recording's query pools return to the free list once it
    /// completes. Under the lock.
    func retireVisibilityPools(_ rec: Recording, serial: UInt64) {
        guard !rec.visibilityPools.isEmpty else { return }
        let pools = rec.visibilityPools
        rec.visibilityPools.removeAll()
        rec.visibilityPool = nil
        graveyard.append((serial, { [unowned self] in self.freeVisibilityPools.append(contentsOf: pools) }))
    }

    /// Mode change (record 132): the running segment ends.
    func setVisibilityMode(_ v: inout VisibilityQueries, _ mode: UInt64, offset: Int, _ cb: VkCommandBuffer?) {
        endVisibilityQuery(&v, cb)
        v.mode = mode
        v.offset = offset
        if mode != 0 && Self.visibilityLogged < 12 {
            noteVisibility("visibility: mode \(mode) at offset \(offset) of #\(v.bufferHandle.raw) (\(v.buffer.length) B)")
        }
    }

    /// Before a draw: a segment begins if the mode counts and none runs.
    func beginVisibilityQuery(_ v: inout VisibilityQueries, _ cb: VkCommandBuffer?) {
        guard v.mode != 0, !v.active, v.used < v.capacity else { return }
        let q = v.first + v.used
        v.used += 1
        let flags = v.mode == 2 && v.precise ? VK_QUERY_CONTROL_PRECISE_BIT.rawValue : 0
        fn.vkCmdBeginQuery!(cb, v.pool, q, flags)
        v.active = true
        v.segments.append((q, v.offset))
    }

    /// Before rendering ends (pass end, feedback snapshot) or the mode changes.
    func endVisibilityQuery(_ v: inout VisibilityQueries, _ cb: VkCommandBuffer?) {
        guard v.active else { return }
        fn.vkCmdEndQuery!(cb, v.pool, v.first + v.used - 1)
        v.active = false
    }

    /// After rendering ended: each slot receives its query's 64-bit result.
    /// A slot counted by several segments receives the sum in Metal; here it
    /// receives the last segment's count (logged).
    func writeVisibilityResults(_ v: VisibilityQueries, _ cb: VkCommandBuffer?) {
        guard !v.segments.isEmpty else { return }
        var last: [Int: UInt32] = [:]
        var shared = 0
        for s in v.segments {
            if last[s.offset] != nil { shared += 1 }
            last[s.offset] = s.query
        }
        let flags = VK_QUERY_RESULT_64_BIT.rawValue | VK_QUERY_RESULT_WAIT_BIT.rawValue
        for (offset, q) in last {
            guard offset >= 0, offset % 8 == 0, offset + 8 <= v.buffer.length else {
                noteVisibility("visibility: offset \(offset) outside #\(v.bufferHandle.raw) (\(v.buffer.length) B); not written")
                continue
            }
            fn.vkCmdCopyQueryPoolResults!(cb, v.pool, q, 1, v.buffer.vkBuffer, VkDeviceSize(v.buffer.offset + offset), 8, flags)
        }
        statistics.visibilityQueries += v.segments.count
        statistics.visibilitySharedSlots += shared
        if Self.visibilityLogged < 12 || (shared > 0 && Self.visibilityLogged < 24) {
            noteVisibility("visibility: pass with \(v.segments.count) queries into \(last.count) slots of #\(v.bufferHandle.raw)"
                + (shared > 0 ? "; \(shared) segments share a slot (the last one's count is kept)" : ""))
        }
    }

    func noteVisibility(_ message: String) {
        guard Self.visibilityLogged < 24 else { return }
        Self.visibilityLogged += 1
        log(message)
    }
}

// MARK: - Diagnostics: the draws of passes of one size

extension VulkanMetalBackend {
    /// `YCODE_DEBUG_PASS_DRAWS=<width>x<height>`: each render pass of that
    /// size whose draw list differs from the previous such pass's is logged
    /// (host monotonic time, load actions, visibility buffer and slots, and
    /// per draw the functions, index or vertex count, instances, base
    /// instance and the first fragment texture), at most 20000 lines.
    static let debugPassDrawsSize: (Int, Int)? = {
        guard let v = ProcessInfo.processInfo.environment["YCODE_DEBUG_PASS_DRAWS"] else { return nil }
        let p = v.split(separator: "x").compactMap { Int($0) }
        return p.count == 2 ? (p[0], p[1]) : nil
    }()
    nonisolated(unsafe) static var debugPassDrawsLast: [String: String] = [:]
    /// `YCODE_DEBUG_PASS_DRAWS_ALL=<after s>`: every such pass is logged
    /// (no deduplication), from that many seconds after the first one.
    static let debugPassDrawsAllAfter = Double(ProcessInfo.processInfo.environment["YCODE_DEBUG_PASS_DRAWS_ALL"] ?? "")
    nonisolated(unsafe) static var debugPassDrawsFirst: UInt64 = 0
    /// `YCODE_DEBUG_PASS_DRAWS_BUFFERS=1`: the fragment buffers bound at each draw too.
    static let debugPassDrawsBuffers = ProcessInfo.processInfo.environment["YCODE_DEBUG_PASS_DRAWS_BUFFERS"] == "1"
    nonisolated(unsafe) static var debugPassDrawsLines = 0

    func debugPassDraws(_ pass: MetalRenderPass, width: Int, height: Int, process: MetalProcessID) {
        guard let want = Self.debugPassDrawsSize, want == (width, height), Self.debugPassDrawsLines < 20000,
              let d = pass.descriptor else { return }
        func short(_ t: TranslatedShader?) -> String { t?.reflection.entryPoint ?? "-" }
        var pipeline: VKRenderPipeline?
        var fragmentTexture: MetalHandle?
        var fragmentBuffers: [Int: MetalHandle] = [:]
        // The signature leaves out handles (textures and buffers change from
        // frame to frame); the line has them.
        var sig: [String] = [], line: [String] = []
        for c in pass.commands {
            var s: String?, extra = ""
            switch c {
            case .setRenderPipelineState(let h): pipeline = h.flatMap { renderPipelines[$0] }
            case .setTexture(let st, let index, let t) where st == .fragment && index == 0: fragmentTexture = t
            case .setBuffer(let st, let index, let b, _) where st == .fragment: fragmentBuffers[index] = b
            case .setVisibilityResultMode(let m, let off): s = "V\(m)@\(off)"
            case .draw(let dr):
                s = "\(short(pipeline?.vertex))+\(short(pipeline?.fragment)) v\(dr.vertexCount)x\(dr.instanceCount)+\(dr.baseInstance)"
            case .drawIndexed(let dr):
                s = "\(short(pipeline?.vertex))+\(short(pipeline?.fragment)) i\(dr.indexCount)x\(dr.instanceCount)+\(dr.baseInstance)"
                extra = " ib\(dr.indexBuffer?.raw ?? 0) t\(fragmentTexture?.raw ?? 0)"
                    + (Self.debugPassDrawsBuffers ? " fb" + fragmentBuffers.sorted { $0.key < $1.key }
                        .map { "\($0.key):\($0.value.raw)" }.joined(separator: ",") : "")
            case .drawIndirect, .drawIndexedIndirect:
                s = "\(short(pipeline?.vertex))+\(short(pipeline?.fragment)) indirect"
            default: break
            }
            if let s { sig.append(s); line.append(s + extra) }
        }
        let loads = (d.colorAttachments.map { "c\($0.index):\($0.attachment.loadAction)/\($0.attachment.storeAction)"
                + (Self.debugPassDrawsAllAfter != nil ? " #\($0.attachment.texture?.raw ?? 0)" : "") }
            + [d.depth.map { "d:\($0.loadAction)/\($0.storeAction) \(d.clearDepth)" }].compactMap { $0 }).joined(separator: " ")
        var visBuf = ""
        if let vh = d.visibilityResultBuffer, let vb = buffers[vh], let p = vb.hostPointer {
            let n = min(vb.length / 8, 4)
            visBuf = " vbuf #\(vh.raw) [" + (0..<n).map { String(p.load(fromByteOffset: 8 * $0, as: UInt64.self)) }.joined(separator: ",") + "]"
        }
        let signature = loads + " | " + sig.joined(separator: "; ")
        let key = "\(process) \(signature.prefix(40))"
        let now = DispatchTime.now().uptimeNanoseconds
        if Self.debugPassDrawsFirst == 0 { Self.debugPassDrawsFirst = now }
        let all = Self.debugPassDrawsAllAfter.map { Double(now - Self.debugPassDrawsFirst) / 1e9 >= $0 } ?? false
        guard all || Self.debugPassDrawsLast[key] != signature || !visBuf.isEmpty else { return }
        Self.debugPassDrawsLast[key] = signature
        Self.debugPassDrawsLines += 1
        log("pass draws \(width)x\(height) t=\(DispatchTime.now().uptimeNanoseconds) process \(process): \(loads)\(visBuf) | "
            + line.joined(separator: "; "))
    }
}
