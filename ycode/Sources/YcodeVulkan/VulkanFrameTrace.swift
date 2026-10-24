// The GPU frame trace (diagnostics, `YCODE_METAL_TRACE=<file>`): one line
// per Metal command buffer with the host times of every step from the
// service receiving it to the completion handlers, the GPU's own begin and
// end timestamps, and what it did (draws, dispatches, IOSurface bytes
// copied in and out, surfaces written). Without the variable nothing here
// runs and no timestamp is recorded. Format: stage8-contract.md §14.

import CVulkan
import Foundation
import YcodeMetalHost

/// What one Metal command buffer's trace line holds (filled while it is
/// recorded; finished on the completion thread).
struct FrameTraceInfo {
    var process: MetalProcessID
    var commandBufferRef: UInt64
    /// Monotonic ns: the service received it, the back end's `submit`
    /// started, its pipelines were ready, the back-end lock was taken, the
    /// recording was submitted (or held).
    var receivedAt: UInt64 = 0, enteredAt: UInt64 = 0, pipelinesAt: UInt64 = 0, lockedAt: UInt64 = 0, submittedAt: UInt64 = 0
    /// The query-pool pair holding its GPU begin/end timestamps (-1: none).
    var slot = -1
    var draws = 0, dispatches = 0, blits = 0, passes = 0
    var bytesIn = 0, bytesOut = 0
    var surfacesIn: [UInt32] = [], surfacesOut: [UInt32] = []
    var held = false
    /// Segment labels in order (`YCODE_METAL_TRACE_SEGMENTS=1`): a GPU
    /// timestamp follows each segment (copy-ins, every pass, copy-outs).
    var segments: [String] = []
}

/// The trace's file and timestamp pool. Every member is used under the
/// back end's lock except `write`.
final class FrameTrace {
    let pool: VkQueryPool
    let pairs: Int
    let periodNs: Double
    let validMask: UInt64
    private var inUse: [Bool]
    private var next = 0
    private let file: FileHandle
    private let fileLock = NSLock()
    /// Per-segment timestamps (nil unless `YCODE_METAL_TRACE_SEGMENTS=1`):
    /// `segmentsPerSlot` queries per pair slot.
    let segmentPool: VkQueryPool?
    static let segmentsPerSlot = 32

    init?(path: String, ctx: UnsafeMutablePointer<yvk_context>, fn: yvk_dispatch, pairs: Int = 4096) {
        guard let create = fn.vkCreateQueryPool, fn.vkCmdWriteTimestamp2 != nil, fn.vkGetQueryPoolResults != nil,
              fn.vkCmdResetQueryPool != nil else { return nil }
        FileManager.default.createFile(atPath: path, contents: nil)
        guard let f = FileHandle(forWritingAtPath: path) else { return nil }
        var ci = VkQueryPoolCreateInfo(sType: VK_STRUCTURE_TYPE_QUERY_POOL_CREATE_INFO, pNext: nil, flags: 0,
                                       queryType: VK_QUERY_TYPE_TIMESTAMP, queryCount: UInt32(pairs * 2),
                                       pipelineStatistics: 0)
        var p: VkQueryPool?
        guard create(ctx.pointee.device, &ci, nil, &p) == VK_SUCCESS, let p else { return nil }
        pool = p
        var sp: VkQueryPool?
        if ProcessInfo.processInfo.environment["YCODE_METAL_TRACE_SEGMENTS"] == "1" {
            var si = ci
            si.queryCount = UInt32(pairs * Self.segmentsPerSlot)
            if create(ctx.pointee.device, &si, nil, &sp) != VK_SUCCESS { sp = nil }
        }
        segmentPool = sp
        self.pairs = pairs
        periodNs = Double(ctx.pointee.properties.limits.timestampPeriod)
        validMask = .max // the queue's timestampValidBits are 64 on the hosts used; ticks are masked anyway
        inUse = [Bool](repeating: false, count: pairs)
        file = f
        file.write(Data(("# ycode GPU frame trace v1: pid cbref recv_ns enter_ns pipelines_ns locked_ns submitted_ns "
            + "gpu_begin_ns gpu_end_ns done_ns handlers_ns draws dispatches blits passes bytes_in bytes_out held "
            + "surfaces_in surfaces_out [segments: label=ns after gpu_begin,...] (gpu_* in the GPU's clock, '-' when absent)\n").utf8))
    }

    /// A free timestamp pair, or -1 when all are in flight. Under the lock.
    func allocate() -> Int {
        for _ in 0..<pairs {
            let i = next
            next = (next + 1) % pairs
            if !inUse[i] { inUse[i] = true; return i }
        }
        return -1
    }

    /// Frees a pair that was never submitted. Under the lock.
    func release(_ slot: Int) {
        if slot >= 0 { inUse[slot] = false }
    }

    /// Records the begin timestamp (and resets the pair first). Under the lock.
    func begin(_ cb: VkCommandBuffer?, _ fn: yvk_dispatch, slot: Int) {
        guard slot >= 0 else { return }
        if let sp = segmentPool {
            fn.vkCmdResetQueryPool!(cb, sp, UInt32(slot * Self.segmentsPerSlot), UInt32(Self.segmentsPerSlot))
        }
        fn.vkCmdResetQueryPool!(cb, pool, UInt32(slot * 2), 2)
        fn.vkCmdWriteTimestamp2!(cb, VK_PIPELINE_STAGE_2_TOP_OF_PIPE_BIT, pool, UInt32(slot * 2))
    }

    /// A timestamp after everything recorded so far (one segment). Under the lock.
    func segment(_ cb: VkCommandBuffer?, _ fn: yvk_dispatch, slot: Int, _ labels: inout [String], _ label: @autoclosure () -> String) {
        guard let sp = segmentPool, slot >= 0, labels.count < Self.segmentsPerSlot else { return }
        fn.vkCmdWriteTimestamp2!(cb, VK_PIPELINE_STAGE_2_ALL_COMMANDS_BIT, sp, UInt32(slot * Self.segmentsPerSlot + labels.count))
        labels.append(label())
    }

    /// The segment times (GPU ns) of a completed slot. Under the lock, before `results`.
    func segmentResults(_ device: VkDevice?, _ fn: yvk_dispatch, slot: Int, count: Int) -> [UInt64]? {
        guard let sp = segmentPool, slot >= 0, count > 0 else { return nil }
        var v = [UInt64](repeating: 0, count: count)
        let r = v.withUnsafeMutableBytes { raw in
            fn.vkGetQueryPoolResults!(device, sp, UInt32(slot * Self.segmentsPerSlot), UInt32(count), raw.count, raw.baseAddress, 8,
                                      VkQueryResultFlags(VK_QUERY_RESULT_64_BIT.rawValue))
        }
        guard r == VK_SUCCESS else { return nil }
        return v.map { UInt64(Double($0 & validMask) * periodNs) }
    }

    func end(_ cb: VkCommandBuffer?, _ fn: yvk_dispatch, slot: Int) {
        guard slot >= 0 else { return }
        fn.vkCmdWriteTimestamp2!(cb, VK_PIPELINE_STAGE_2_ALL_COMMANDS_BIT, pool, UInt32(slot * 2 + 1))
    }

    /// The GPU begin/end times (ns in the GPU's clock) of a completed pair,
    /// which is then free again. Under the lock.
    func results(_ device: VkDevice?, _ fn: yvk_dispatch, slot: Int) -> (UInt64, UInt64)? {
        guard slot >= 0 else { return nil }
        defer { inUse[slot] = false }
        var v: (UInt64, UInt64) = (0, 0)
        let r = withUnsafeMutableBytes(of: &v) { raw in
            fn.vkGetQueryPoolResults!(device, pool, UInt32(slot * 2), 2, 16, raw.baseAddress, 8,
                                      VkQueryResultFlags(VK_QUERY_RESULT_64_BIT.rawValue))
        }
        guard r == VK_SUCCESS else { return nil }
        return (UInt64(Double(v.0 & validMask) * periodNs), UInt64(Double(v.1 & validMask) * periodNs))
    }

    func line(_ t: FrameTraceInfo, gpu: (UInt64, UInt64)?, segments: [UInt64]? = nil, done: UInt64, handlers: UInt64) -> String {
        func ids(_ a: [UInt32]) -> String { a.isEmpty ? "-" : a.map(String.init).joined(separator: ",") }
        let g = gpu.map { ("\($0.0)", "\($0.1)") } ?? ("-", "-")
        var segs = ""
        if let s = segments, let begin = gpu?.0, s.count == t.segments.count {
            segs = " " + zip(t.segments, s).map { "\($0.0)=\($0.1 >= begin ? $0.1 - begin : 0)" }.joined(separator: ",")
        }
        return "\(t.process) \(t.commandBufferRef) \(t.receivedAt) \(t.enteredAt) \(t.pipelinesAt) \(t.lockedAt) \(t.submittedAt) "
            + "\(g.0) \(g.1) \(done) \(handlers) \(t.draws) \(t.dispatches) \(t.blits) \(t.passes) \(t.bytesIn) \(t.bytesOut) "
            + "\(t.held ? 1 : 0) \(ids(t.surfacesIn)) \(ids(t.surfacesOut))\(segs)\n"
    }

    /// Appends lines (any thread).
    func write(_ lines: [String]) {
        guard !lines.isEmpty else { return }
        fileLock.withLock { file.write(Data(lines.joined().utf8)) }
    }

    func destroy(_ device: VkDevice?, _ fn: yvk_dispatch) {
        fn.vkDestroyQueryPool?(device, pool, nil)
        if let sp = segmentPool { fn.vkDestroyQueryPool?(device, sp, nil) }
        fileLock.withLock { try? file.close() }
    }
}
