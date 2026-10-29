// Pass probes (diagnostics; visionos.md §10.20): where the pixels of a
// frame are lost.
//
// `YCODE_GPU_PROBE=<names>` (comma-separated function names, entry point or
// `entry#hash8`): a command buffer with a draw or dispatch of such a function
// is probed. Its description (VulkanHangReport.swift) is logged, and
// copies are recorded into a host buffer of the probe's own:
//
// - before every pass, each texture the pass binds for reading (level 0 of
//   the binding, up to six layers) and each attachment it loads;
// - after every pass, each attachment it stores or resolves into (the
//   attachment's level and slice), each texture a kernel of the pass may
//   write, and each blit destination.
//
// When the GPU has finished, one line per copy gives the texels that are
// not zero, and per format class the channel means, alpha counts, the
// number of NaN or infinite values and the range. Draws the replay skipped
// in that command buffer are listed with the source line that skipped
// them. `YCODE_GPU_PROBE_MAX` (default 4) probes at most, at least
// `YCODE_GPU_PROBE_INTERVAL_S` (default 20) s apart; `YCODE_GPU_PROBE_MB`
// (default 1536) caps the bytes one probe copies.
//
// `YCODE_GPU_PROBE_DUMP=<dir>`: each probed copy's bytes are also written
// to <dir>/probe<N>-p<pass>-<in|out>-t<handle>-L<level>-S<slice>.bin (raw
// texels, tightly packed rows) for offline viewing.

import CVulkan
import Foundation
import YcodeMetalHost

/// One probed command buffer: the copies recorded into its buffer.
final class PassProbe: @unchecked Sendable {
    struct Copy {
        var pass: Int
        var when: String
        var what: String
        var handle: UInt64
        var level: Int
        var slice: Int
        var offset: Int
        var width: Int
        var height: Int
        var bytesPerBlock: Int
        var format: VkFormat
        var compressed: Bool
        var depth: Bool
    }

    let number: Int
    let label: String
    var buffer = yvk_buffer()
    let capacity: Int
    var used = 0
    var copies: [Copy] = []
    var notes: [String] = []
    /// Inputs already copied (handle, level, layer): a texture read by
    /// several passes is copied before the first only.
    var seenInputs: Set<String> = []
    var budgetExhausted = false

    init(number: Int, label: String, capacity: Int) {
        self.number = number
        self.label = label
        self.capacity = capacity
    }
}

extension VulkanMetalBackend {
    static let probeNames: Set<String> = Set((ProcessInfo.processInfo.environment["YCODE_GPU_PROBE"] ?? "")
        .split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
    static let probeMax = Int(ProcessInfo.processInfo.environment["YCODE_GPU_PROBE_MAX"] ?? "") ?? 4
    static let probeInterval = Double(ProcessInfo.processInfo.environment["YCODE_GPU_PROBE_INTERVAL_S"] ?? "") ?? 20
    static let probeBytes = (Int(ProcessInfo.processInfo.environment["YCODE_GPU_PROBE_MB"] ?? "") ?? 1536) << 20
    static let probeDump = ProcessInfo.processInfo.environment["YCODE_GPU_PROBE_DUMP"]
    /// `YCODE_GPU_PROBE_AFTER_S`: no probe before this many seconds after the
    /// first submission (a probe copies hundreds of MiB and delays the
    /// guest's GPU work; early in a visionOS boot that kept the home view
    /// from launching).
    static let probeStartDelay = Double(ProcessInfo.processInfo.environment["YCODE_GPU_PROBE_AFTER_S"] ?? "") ?? 0
    nonisolated(unsafe) static var probeEpoch: UInt64 = 0

    /// Whether a shader's name is one of `YCODE_GPU_PROBE`'s.
    func probeMatches(_ s: TranslatedShader?) -> Bool {
        guard let s else { return false }
        return Self.probeNames.contains(s.reflection.entryPoint ?? "") || Self.probeNames.contains(shaderName(s))
    }

    /// Starts a probe of `mcb` when it uses a probed function and the
    /// budget allows. Under the lock, before the replay.
    func beginProbe(_ mcb: MetalCommandBuffer) {
        guard !Self.probeNames.isEmpty, probesStarted < Self.probeMax else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        if Self.probeEpoch == 0 { Self.probeEpoch = now }
        if Double(now &- Self.probeEpoch) / 1e9 < Self.probeStartDelay { return }
        if probesStarted > 0, Double(now &- lastProbeAt) / 1e9 < Self.probeInterval { return }
        var hit = false
        scan: for pass in mcb.passes {
            switch pass {
            case .render(let p):
                for c in p.commands {
                    if case .setRenderPipelineState(let h) = c, let h, let rp = renderPipelines[h],
                       probeMatches(rp.vertex) || probeMatches(rp.fragment) { hit = true; break scan }
                }
            case .compute(let cmds):
                for c in cmds {
                    if case .setComputePipelineState(let h) = c, let h, let cp = computePipelines[h], probeMatches(cp.shader) {
                        hit = true; break scan
                    }
                }
            default: break
            }
        }
        guard hit else { return }
        probesStarted += 1
        lastProbeAt = now
        let p = PassProbe(number: probesStarted, label: "process \(mcb.process) command buffer \(mcb.commandBufferRef)",
                          capacity: Self.probeBytes)
        var err = [CChar](repeating: 0, count: 256)
        guard yvk_buffer_create(ctx, VkDeviceSize(p.capacity), YVK_MEMORY_HOST, nil, &p.buffer, &err, err.count) == 0,
              p.buffer.mapped != nil else {
            log("probe \(p.number): no host buffer of \(p.capacity >> 20) MiB: \(cString(err))")
            return
        }
        log("probe \(p.number): \(p.label), \(mcb.passes.count) passes\n    " + describeCommandBuffer(mcb, limit: 600))
        probe = p
    }

    /// Records a copy of one level and layer of `h` into the probe's buffer.
    func probeCopy(_ p: PassProbe, _ cb: VkCommandBuffer?, pass: Int, when: String, _ h: MetalHandle?, level: Int, slice: Int) {
        guard let h, let tex = textures[h] else { return }
        if when == "in" {
            guard p.seenInputs.insert("\(h.raw)/\(level)/\(slice)").inserted else { return }
        }
        let what = describeTexture(h) + (tex.textureType == MetalTextureType.typeCube ? " cube" : "")
            + (tex.layerCount > 1 ? " layers \(tex.layerCount)" : "")
            + " {slot \(tex.heapIndex)" + (tex.heapCount > 1 ? "+\(tex.heapCount)" : "")
            + (tex.shaderView == nil ? " no sampled view" : "") + (tex.storageView == nil ? " no storage view" : " storage")
            + " usage 0x\(String(tex.metalUsage, radix: 16)) type \(tex.textureType)"
            + (tex.baseLevel != 0 || tex.levelCount != tex.image.levels ? " levels \(tex.baseLevel)+\(tex.levelCount) of \(tex.image.levels)" : "")
            + (tex.format.format != tex.image.format.format ? " view vk \(tex.format.format.rawValue) of \(tex.image.format.format.rawValue)" : "")
            + "}"
        guard tex.image.samples == 1 else {
            p.notes.append("pass \(pass) \(when) \(what): multisampled, not copied")
            return
        }
        guard level < tex.levelCount, slice < (tex.image.imageType == VK_IMAGE_TYPE_3D ? 1 : tex.layerCount) else { return }
        let (aspect, bpb) = copyAspect(tex)
        let f = tex.format
        let (w, hh, _) = tex.levelSize(level)
        let bw = (w + f.blockWidth - 1) / f.blockWidth, bh = (hh + f.blockHeight - 1) / f.blockHeight
        let bytes = bw * bh * bpb
        let offset = roundUp(p.used, lcm(16, max(bpb, 4)))
        guard bytes > 0, offset + bytes <= p.capacity else {
            if !p.budgetExhausted { p.notes.append("byte budget reached at pass \(pass) \(when) \(what)") }
            p.budgetExhausted = true
            return
        }
        p.used = offset + bytes
        var region = VkBufferImageCopy(
            bufferOffset: VkDeviceSize(offset), bufferRowLength: 0, bufferImageHeight: 0,
            imageSubresource: VkImageSubresourceLayers(aspectMask: aspect, mipLevel: UInt32(tex.baseLevel + level),
                                                       baseArrayLayer: UInt32(tex.image.imageType == VK_IMAGE_TYPE_3D ? 0 : tex.baseLayer + slice),
                                                       layerCount: 1),
            imageOffset: VkOffset3D(x: 0, y: 0, z: 0), imageExtent: VkExtent3D(width: UInt32(w), height: UInt32(hh), depth: 1))
        fn.vkCmdCopyImageToBuffer!(cb, tex.image.vkImage, VK_IMAGE_LAYOUT_GENERAL, p.buffer.buffer, 1, &region)
        p.copies.append(PassProbe.Copy(pass: pass, when: when, what: what, handle: h.raw, level: level, slice: slice, offset: offset,
                                       width: bw, height: bh, bytesPerBlock: bpb, format: f.format, compressed: f.isCompressed,
                                       depth: !f.isColor))
    }

    /// Records a copy of (at most `probeBufferBytes` of) a buffer from `offset` on.
    func probeBuffer(_ p: PassProbe, _ cb: VkCommandBuffer?, pass: Int, when: String, _ h: MetalHandle?, offset: Int,
                     limit: Int = Int.max) {
        guard let h, let b = buffers[h], offset >= 0, offset < b.length else { return }
        if when == "in" {
            guard p.seenInputs.insert("b\(h.raw)/\(offset)").inserted else { return }
        }
        let bytes = min(b.length - offset, Self.probeBufferBytes, limit, Int(b.allocation.buffer.size) - b.offset - offset)
        let at = roundUp(p.used, 16)
        guard bytes > 0, at + bytes <= p.capacity else { return }
        p.used = at + bytes
        var region = VkBufferCopy(srcOffset: VkDeviceSize(b.offset + offset), dstOffset: VkDeviceSize(at), size: VkDeviceSize(bytes))
        fn.vkCmdCopyBuffer!(cb, b.vkBuffer, p.buffer.buffer, 1, &region)
        p.copies.append(PassProbe.Copy(pass: pass, when: when, what: describeBuffer(h, offset) + (bytes < b.length - offset ? " (first \(bytes) B)" : ""),
                                       handle: h.raw, level: -1, slice: offset, offset: at, width: bytes, height: 1, bytesPerBlock: 1,
                                       format: VK_FORMAT_UNDEFINED, compressed: false, depth: false))
    }
    static let probeBufferBytes = (Int(ProcessInfo.processInfo.environment["YCODE_GPU_PROBE_BUFFER_KB"] ?? "") ?? 16384) << 10

    /// Every layer (up to six) of level 0 of a bound texture.
    func probeTexture(_ p: PassProbe, _ cb: VkCommandBuffer?, pass: Int, when: String, _ h: MetalHandle?) {
        guard let h, let tex = textures[h] else { return }
        let layers = tex.image.imageType == VK_IMAGE_TYPE_3D ? 1 : min(tex.layerCount, 6)
        for s in 0..<layers { probeCopy(p, cb, pass: pass, when: when, h, level: 0, slice: s) }
    }

    /// Copies of what a pass reads, before it. Under the lock, outside a rendering.
    func probeBefore(_ pass: MetalPass, _ index: Int, _ cb: VkCommandBuffer?) {
        guard let p = probe else { return }
        barrier(cb)
        switch pass {
        case .render(let rp):
            if let d = rp.descriptor {
                var atts = d.colorAttachments.map(\.attachment)
                if let a = d.depth { atts.append(a) }
                for a in atts where a.loadAction == MetalLoadAction.load {
                    probeCopy(p, cb, pass: index, when: "in", a.texture, level: a.level, slice: a.slice)
                }
            }
            for c in rp.commands { if case .setTexture(_, _, let t) = c { probeTexture(p, cb, pass: index, when: "in", t) } }
            // The buffers bound at each draw of a probed function (64 KiB of each at most).
            var pipeline: VKRenderPipeline?
            var bound: [String: (MetalHandle?, Int)] = [:]
            for c in rp.commands {
                switch c {
                case .setRenderPipelineState(let h): pipeline = h.flatMap { renderPipelines[$0] }
                case .setBuffer(let st, let i, let b, let o): bound["\(st == .vertex ? "v" : "f")\(i)"] = (b, o)
                case .setBufferOffset(let st, let i, let o):
                    let k = "\(st == .vertex ? "v" : "f")\(i)"
                    bound[k] = (bound[k]?.0, o)
                case .draw, .drawIndexed, .drawIndirect, .drawIndexedIndirect:
                    guard let pl = pipeline, probeMatches(pl.vertex) || probeMatches(pl.fragment) else { continue }
                    for (_, (b, o)) in bound.sorted(by: { $0.key < $1.key }) {
                        probeBuffer(p, cb, pass: index, when: "in", b, offset: o, limit: 65536)
                    }
                default: break
                }
            }
        case .compute(let cmds):
            for c in cmds {
                switch c {
                case .setTexture(_, let t): probeTexture(p, cb, pass: index, when: "in", t)
                case .setBuffer(_, let b, let o): probeBuffer(p, cb, pass: index, when: "in", b, offset: o)
                default: break
                }
            }
        case .blit(let cmds):
            for c in cmds {
                if case .copyBufferToBuffer(let s, let so, _, _, _) = c { probeBuffer(p, cb, pass: index, when: "in", s, offset: so) }
                if case .copyBufferToTexture(let s, let so, _, _, _, _, _, _, _, _) = c { probeBuffer(p, cb, pass: index, when: "in", s, offset: so) }
            }
        default: break
        }
        barrier(cb)
    }

    /// Copies of what a pass wrote, after it. Under the lock, outside a rendering.
    func probeAfter(_ pass: MetalPass, _ index: Int, _ cb: VkCommandBuffer?) {
        guard let p = probe else { return }
        barrier(cb)
        switch pass {
        case .render(let rp):
            guard let d = rp.descriptor else { break }
            for c in d.colorAttachments {
                probeCopy(p, cb, pass: index, when: "out c\(c.index)", c.texture, level: c.attachment.level, slice: c.attachment.slice)
                if c.resolveTexture != nil {
                    probeCopy(p, cb, pass: index, when: "out r\(c.index)", c.resolveTexture, level: 0, slice: 0)
                }
            }
            if let a = d.depth { probeCopy(p, cb, pass: index, when: "out d", a.texture, level: a.level, slice: a.slice) }
        case .compute(let cmds):
            var pipeline: VKComputePipeline?
            var bound: [Int: MetalHandle?] = [:]
            var written: [UInt64: MetalHandle] = [:]
            for c in cmds {
                switch c {
                case .setComputePipelineState(let h): pipeline = h.flatMap { computePipelines[$0] }
                case .setTexture(let i, let t): bound[i] = t
                case .dispatchThreads, .dispatchThreadgroups, .dispatchThreadgroupsIndirect:
                    for t in pipeline?.shader?.reflection.textures ?? [] where (t.access ?? "").contains("write") {
                        // swiftlint:disable:next redundant_nil_coalescing - flattens a double optional
                        if let h = bound[t.index] ?? nil { written[h.raw] = h }
                    }
                default: break
                }
            }
            for (_, h) in written.sorted(by: { $0.key < $1.key }) { probeTexture(p, cb, pass: index, when: "out", h) }
        case .blit(let cmds):
            for c in cmds {
                switch c {
                case .copyBufferToTexture(_, _, _, _, _, let d, let slice, let level, _, _):
                    probeCopy(p, cb, pass: index, when: "out", d, level: level, slice: slice)
                case .copyTextureToTexture(_, _, _, _, _, let d, let ds, let dl, _):
                    probeCopy(p, cb, pass: index, when: "out", d, level: dl, slice: ds)
                case .copyTextureSlices(_, _, _, let d, let ds, let dl, _, _):
                    probeCopy(p, cb, pass: index, when: "out", d, level: dl, slice: ds)
                case .generateMipmaps(let t): probeTexture(p, cb, pass: index, when: "out", t)
                case .copyBufferToBuffer(_, _, let d, let dO, _): probeBuffer(p, cb, pass: index, when: "out", d, offset: dO)
                default: break
                }
            }
        default: break
        }
        barrier(cb)
    }

    /// A draw of the probed command buffer that the replay skipped. Under the lock.
    func probeNoteSkip(pass: Int, command: Int, _ what: String) {
        guard let p = probe else { return }
        if p.notes.count < 200 { p.notes.append("pass \(pass) command \(command) \(what) skipped (replay line \(lastSkipLine))") }
    }

    /// Ends the probe of the command buffer just replayed: its results are
    /// read when the GPU has finished. Under the lock.
    func endProbe(_ entry: inout PendingSubmission) {
        guard let p = probe else { return }
        probe = nil
        let earlier = entry.after
        let logger = options.log
        entry.after = { [self] ok in
            earlier?(ok)
            DispatchQueue.global(qos: .utility).async {
                if ok {
                    for line in Self.probeReport(p) { logger?("[vulkan] " + line) }
                } else {
                    logger?("[vulkan] probe \(p.number): the command buffer failed; no results")
                }
                yvk_buffer_destroy(self.ctx, &p.buffer)
            }
        }
    }

    /// A probe abandoned (the replay failed). Under the lock.
    func abandonProbe() {
        guard let p = probe else { return }
        probe = nil
        log("probe \(p.number): replay failed")
        deferDestroy { [ctx] in yvk_buffer_destroy(ctx, &p.buffer) }
    }

    // MARK: Statistics

    static func probeReport(_ p: PassProbe) -> [String] {
        var lines = ["probe \(p.number): results for \(p.label) (\(p.copies.count) copies, \(p.used >> 20) MiB)"]
        for n in p.notes { lines.append("probe \(p.number):   note: \(n)") }
        guard let base = p.buffer.mapped else { return lines }
        for c in p.copies {
            let stats = probeStatistics(base + c.offset, c)
            lines.append("probe \(p.number):   pass \(c.pass) \(c.when) \(c.what)" + (c.level >= 0 ? " L\(c.level) S\(c.slice)" : "") + ": \(stats)")
            if let dir = probeDump {
                let path = c.level < 0
                    ? "\(dir)/probe\(p.number)-p\(c.pass)-\(c.when)-b\(c.handle)-o\(c.slice)-\(c.width).bin"
                    : "\(dir)/probe\(p.number)-p\(c.pass)-\(c.when.replacingOccurrences(of: " ", with: ""))-t\(c.handle)-L\(c.level)-S\(c.slice)"
                        + "-\(c.width)x\(c.height)-f\(c.format.rawValue).bin"
                FileManager.default.createFile(atPath: path, contents: Data(bytes: base + c.offset, count: c.width * c.height * c.bytesPerBlock))
            }
        }
        return lines
    }

    /// Texel statistics of one copy (tightly packed rows of blocks).
    static func probeStatistics(_ ptr: UnsafeMutableRawPointer, _ c: PassProbe.Copy) -> String {
        if c.level < 0 {
            let b = ptr.assumingMemoryBound(to: UInt8.self)
            var nz = 0, first = -1
            for i in 0..<c.width where b[i] != 0 { nz += 1; if first < 0 { first = i } }
            let head = (0..<min(64, c.width)).map { String(format: "%02x", b[$0]) }.joined()
            return "\(c.width) B, \(nz) bytes not zero" + (first >= 0 ? ", first at \(first)" : "") + "; head \(head)"
        }
        let n = c.width * c.height
        let bpb = c.bytesPerBlock
        var nonZero = 0
        let bytes = ptr.assumingMemoryBound(to: UInt8.self)
        for i in 0..<n {
            var any: UInt8 = 0
            for k in 0..<bpb { any |= bytes[i * bpb + k] }
            if any != 0 { nonZero += 1 }
        }
        var text = "\(c.width)x\(c.height) \(c.compressed ? "blocks" : "texels"), \(nonZero) not zero"
        if c.compressed || nonZero == 0 { return text }
        func halfToFloat(_ h: UInt16) -> Float { Float(Float16(bitPattern: h)) }
        func floats(_ count: Int, _ read: (Int, Int) -> Float) -> String {
            var sums = [Double](repeating: 0, count: count)
            var mins = [Float](repeating: .infinity, count: count), maxs = [Float](repeating: -.infinity, count: count)
            var bad = 0
            for i in 0..<n {
                for k in 0..<count {
                    let v = read(i, k)
                    if !v.isFinite { bad += 1; continue }
                    sums[k] += Double(v); mins[k] = min(mins[k], v); maxs[k] = max(maxs[k], v)
                }
            }
            let parts = (0..<count).map { String(format: "%.4g [%.3g, %.3g]", sums[$0] / Double(n), mins[$0], maxs[$0]) }
            return "; mean [range] " + parts.joined(separator: ", ") + (bad > 0 ? "; \(bad) NaN or infinite" : "")
        }
        switch c.format {
        case VK_FORMAT_R8G8B8A8_UNORM, VK_FORMAT_R8G8B8A8_SRGB, VK_FORMAT_B8G8R8A8_UNORM, VK_FORMAT_B8G8R8A8_SRGB:
            var sums = [Int](repeating: 0, count: 4)
            var nonBlack = 0, opaque = 0, transparent = 0
            for i in 0..<n {
                let o = i * 4
                if bytes[o] | bytes[o + 1] | bytes[o + 2] != 0 { nonBlack += 1 }
                if bytes[o + 3] == 255 { opaque += 1 } else if bytes[o + 3] == 0 { transparent += 1 }
                for k in 0..<4 { sums[k] += Int(bytes[o + k]) }
            }
            text += ", \(nonBlack) not black, alpha 255: \(opaque), alpha 0: \(transparent); mean bytes \(sums.map { $0 / n })"
        case VK_FORMAT_R16G16B16A16_SFLOAT:
            let h = ptr.assumingMemoryBound(to: UInt16.self)
            text += floats(4) { halfToFloat(h[$0 * 4 + $1]) }
        case VK_FORMAT_R16G16_SFLOAT:
            let h = ptr.assumingMemoryBound(to: UInt16.self)
            text += floats(2) { halfToFloat(h[$0 * 2 + $1]) }
        case VK_FORMAT_R16_SFLOAT:
            let h = ptr.assumingMemoryBound(to: UInt16.self)
            text += floats(1) { i, _ in halfToFloat(h[i]) }
        case VK_FORMAT_R32_SFLOAT, VK_FORMAT_D32_SFLOAT, VK_FORMAT_D32_SFLOAT_S8_UINT:
            let f = ptr.assumingMemoryBound(to: Float.self)
            text += floats(1) { i, _ in f[i] }
        case VK_FORMAT_R32G32_SFLOAT:
            let f = ptr.assumingMemoryBound(to: Float.self)
            text += floats(2) { f[$0 * 2 + $1] }
        case VK_FORMAT_R32G32B32A32_SFLOAT:
            let f = ptr.assumingMemoryBound(to: Float.self)
            text += floats(4) { f[$0 * 4 + $1] }
        case VK_FORMAT_R8_UNORM, VK_FORMAT_R8G8_UNORM:
            let k = c.format == VK_FORMAT_R8_UNORM ? 1 : 2
            text += floats(k) { Float(bytes[$0 * k + $1]) / 255 }
        case VK_FORMAT_B10G11R11_UFLOAT_PACK32:
            let w = ptr.assumingMemoryBound(to: UInt32.self)
            func small(_ bits: UInt32, mantissa: UInt32) -> Float {
                let m = bits & ((1 << mantissa) - 1), e = bits >> mantissa
                if e == 0 { return Float(m) / Float(1 << mantissa) * powf(2, -14) }
                if e == 31 { return m == 0 ? .infinity : .nan }
                return (1 + Float(m) / Float(1 << mantissa)) * powf(2, Float(Int(e) - 15))
            }
            text += floats(3) { i, k in
                let v = w[i]
                switch k {
                case 0: return small(v & 0x7FF, mantissa: 6)
                case 1: return small((v >> 11) & 0x7FF, mantissa: 6)
                default: return small(v >> 22, mantissa: 5)
                }
            }
        default:
            break
        }
        return text
    }
}
