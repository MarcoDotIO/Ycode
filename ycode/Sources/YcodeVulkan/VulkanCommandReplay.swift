// Command replay: a decoded Metal command buffer (YcodeMetalHost's command
// model) recorded into Vulkan command buffers. Unknown handles and
// unsupported commands are skipped (counted in `statistics.skipped`),
// never fatal.

import CVulkan
import Foundation
import YcodeMetalHost

/// Metal's integer color formats (clear values and resolve modes).
enum MetalIntegerFormats {
    static let unsigned: Set<UInt32> = [13, 23, 33, 53, 63, 73, 91, 103, 113, 123]
    static let signed: Set<UInt32> = [14, 24, 34, 54, 64, 74, 104, 114, 124]
    static let all = unsigned.union(signed)
}

/// A sampler binding with an optional LOD clamp override.
struct SamplerBinding {
    var sampler: MetalHandle?
    var lodMin: Float?
    var lodMax: Float?
}

/// The binding state of one stage (Metal slots).
struct StageBindings {
    var buffers = [(MetalHandle?, Int)](repeating: (nil, 0), count: YcodeMetalABI.bufferSlots)
    var textures = [MetalHandle?](repeating: nil, count: YcodeMetalABI.textureSlots)
    var samplers = [SamplerBinding](repeating: SamplerBinding(), count: YcodeMetalABI.samplerSlots)
    var dirty = true
    var table: UInt64 = 0
    /// Slots that hold something (bit i: slot i), so a table write visits
    /// only those.
    var bufferMask: UInt32 = 0
    var textureMask: (UInt64, UInt64) = (0, 0)
    var samplerMask: UInt16 = 0

    mutating func setBuffer(_ i: Int, _ h: MetalHandle?, _ offset: Int) {
        buffers[i] = (h, offset)
        if h != nil { bufferMask |= 1 << UInt32(i) } else { bufferMask &= ~(1 << UInt32(i)) }
    }

    mutating func setTexture(_ i: Int, _ h: MetalHandle?) {
        textures[i] = h
        let bit = UInt64(1) << UInt64(i & 63)
        if i < 64 {
            if h != nil { textureMask.0 |= bit } else { textureMask.0 &= ~bit }
        } else {
            if h != nil { textureMask.1 |= bit } else { textureMask.1 &= ~bit }
        }
    }

    mutating func setSampler(_ i: Int, _ s: SamplerBinding) {
        samplers[i] = s
        if s.sampler != nil { samplerMask |= 1 << UInt16(i) } else { samplerMask &= ~(1 << UInt16(i)) }
    }
}

/// The set bits of a mask, lowest first.
@inline(__always)
func forEachBit<T: FixedWidthInteger>(_ mask: T, offset: Int = 0, _ body: (Int) throws -> Void) rethrows {
    var m = mask
    while m != 0 {
        let i = m.trailingZeroBitCount
        try body(offset + i)
        m &= m &- 1
    }
}

extension VulkanMetalBackend {
    public func submit(_ commandBuffer: MetalCommandBuffer, scheduled: @escaping @Sendable () -> Void,
                       completed: @escaping @Sendable (_ status: Int) -> Void) {
        guard isAvailable else {
            scheduled()
            completed(MetalCommandBufferStatus.completed)
            return
        }
        // Pipelines still translating or compiling are waited for here,
        // outside the lock (VulkanPipelines.swift).
        let enteredAt = DispatchTime.now().uptimeNanoseconds
        preparePipelines(commandBuffer)
        let pipelinesAt = DispatchTime.now().uptimeNanoseconds
        cond.lock()
        let recordStart = DispatchTime.now().uptimeNanoseconds
        defer {
            statistics.recording.add(DispatchTime.now().uptimeNanoseconds &- recordStart)
            cond.unlock()
            flushEarlyScheduled()
        }
        if deviceLost {
            enqueueCompletion(status: MetalCommandBufferStatus.error, scheduled: scheduled, completed: completed)
            return
        }
        var rec: Recording?
        let key = HeldKey(process: commandBuffer.process, queue: commandBuffer.queue)
        let sink = SubmitSink(key: key, holding: held[key] != nil)
        defer { hold(sink) }
        var trace: FrameTraceInfo?
        let counts = (statistics.dispatches, statistics.blits, statistics.surfaceBytesUp, statistics.surfaceBytesDown)
        if frameTrace != nil {
            trace = FrameTraceInfo(process: commandBuffer.process, commandBufferRef: commandBuffer.commandBufferRef,
                                   receivedAt: commandBuffer.receivedAtNs, enteredAt: enteredAt, pipelinesAt: pipelinesAt,
                                   lockedAt: recordStart, passes: commandBuffer.passes.count)
        }
        do {
            let t0 = profileClock()
            try flushSetup()
            rec = try newRecording()
            registerCheckpoints(rec!, commandBuffer)
            profiled(.start, since: t0)
            if let ft = frameTrace, trace != nil {
                trace!.slot = ft.allocate()
                ft.begin(rec!.cb, fn, slot: trace!.slot)
                if ft.segmentPool != nil { sink.traceSlot = trace!.slot }
            }
            try replay(commandBuffer, rec: &rec!, sink: sink)
            let t1 = profileClock()
            var entry = PendingSubmission(serial: 0, cb: nil, chunks: [], status: MetalCommandBufferStatus.completed,
                                          scheduled: scheduled, completed: completed)
            entry.label = "process \(commandBuffer.process) command buffer \(commandBuffer.commandBufferRef)"
            entry.commandBuffer = commandBuffer
            profiled(.label, since: t1)
            let r = rec!
            rec = nil
            if var t = trace, let ft = frameTrace {
                ft.end(r.cb, fn, slot: t.slot)
                t.draws = r.draws + r.indirectDraws + sink.earlierDraws
                t.dispatches = statistics.dispatches - counts.0
                t.blits = statistics.blits - counts.1
                t.bytesIn = statistics.surfaceBytesUp - counts.2
                t.bytesOut = statistics.surfaceBytesDown - counts.3
                t.surfacesIn = sink.surfacesIn
                t.surfacesOut = sink.surfacesOut
                t.held = sink.holding
                t.segments = sink.segments
                t.submittedAt = DispatchTime.now().uptimeNanoseconds
                entry.trace = t
                trace = nil
            }
            let t2 = profileClock()
            try sinkSubmit(sink, r, entry: entry)
            profiled(.submit, since: t2)
        } catch {
            if let t = trace, let ft = frameTrace { ft.release(t.slot) }
            log("command buffer \(commandBuffer.commandBufferRef) of process \(commandBuffer.process): \(error)")
            if let r = rec {
                _ = fn.vkEndCommandBuffer!(r.cb)
                freeCommandBuffers.append(r.cb!)
                for c in r.chunks { recycle(c) }
            }
            enqueueCompletion(status: MetalCommandBufferStatus.error, scheduled: scheduled, completed: completed)
        }
    }

    // MARK: - IOSurface synchronisation

    /// Images backed by IOSurfaces that the command buffer reads (copied in
    /// first, unless the image already holds the surface's content) and
    /// writes (copied back last: only the part the command buffer can have
    /// changed, `SurfaceDamage`).
    func surfaceUsage(_ mcb: MetalCommandBuffer) -> (reads: [VKImage], writes: [(VKImage, SurfaceDamage)]) {
        var reads: [ObjectIdentifier: VKImage] = [:], writes: [ObjectIdentifier: (VKImage, SurfaceDamage)] = [:]
        func note(_ h: MetalHandle?, read: Bool, write: SurfaceDamage?) {
            guard let h, let t = textures[h], t.image.surface != nil else { return }
            let id = ObjectIdentifier(t.image)
            if read { reads[id] = t.image }
            if let w = write {
                // A view of another level or slice, or of a part of the image, is not tracked: all of it.
                let whole = t.baseLevel != 0 || t.baseLayer != 0
                var d = writes[id]?.1 ?? SurfaceDamage()
                d.add(whole ? .full : w)
                writes[id] = (t.image, d)
            }
        }
        func noteShader(_ h: MetalHandle?) {
            guard let h, let t = textures[h] else { return }
            note(h, read: true, write: t.metalUsage & MetalTextureUsage.shaderWrite != 0 ? .full : nil)
        }
        let limited = options.surfaceDamage
        for pass in mcb.passes {
            switch pass {
            case .render(let p):
                // The area draws can touch: the union of the scissor rects in
                // force at each draw (Metal clips every draw to its scissor
                // rect, which starts as the whole target).
                var drawn = SurfaceDamage()
                if limited {
                    var scissor: MetalScissorRect?
                    for c in p.commands {
                        switch c {
                        case .setScissorRect(let r): scissor = r
                        case .draw, .drawIndexed, .drawIndirect, .drawIndexedIndirect:
                            drawn.add(scissor.map { SurfaceDamage(x: $0.x, y: $0.y, width: $0.width, height: $0.height) } ?? .full)
                        default: break
                        }
                    }
                } else {
                    drawn = .full
                }
                if let d = p.descriptor {
                    var atts = d.colorAttachments.map(\.attachment)
                    if let a = d.depth { atts.append(a) }
                    if let a = d.stencil { atts.append(a) }
                    for a in atts {
                        let load = a.loadAction == MetalLoadAction.load
                        // A clear or don't-care load changes every pixel; a level or slice other than 0 is not tracked.
                        let damage: SurfaceDamage = !load || a.level != 0 || a.slice != 0 ? .full : drawn
                        if damageLogBudget > 0, let h = a.texture, let t = textures[h], let s = t.image.surface {
                            damageLogBudget -= 1
                            let draws = p.commands.filter { if case .draw = $0 { return true }; if case .drawIndexed = $0 { return true }; return false }.count
                            let scissors = p.commands.compactMap { c -> String? in if case .setScissorRect(let r) = c { return "\(r.x),\(r.y) \(r.width)x\(r.height)" }; return nil }
                            log("damage: surface \(s.surfaceID) load \(a.loadAction) store \(a.storeAction) level \(a.level) draws \(draws) "
                                + "scissors \(scissors.prefix(6)) -> \(damage.isFull ? "full" : "\(damage.x0),\(damage.y0)-\(damage.x1),\(damage.y1)")")
                        }
                        note(a.texture, read: load, write: damage)
                        note(a.resolveTexture, read: false, write: .full)
                    }
                }
                for c in p.commands { if case .setTexture(_, _, let t) = c { noteShader(t) } }
            case .compute(let cmds):
                for c in cmds { if case .setTexture(_, let t) = c { noteShader(t) } }
            case .blit(let cmds):
                for c in cmds {
                    switch c {
                    case .copyBufferToTexture(_, _, _, _, _, let d, _, _, _, _): note(d, read: true, write: .full)
                    case .copyTextureToBuffer(let s, _, _, _, _, _, _, _, _, _): note(s, read: true, write: nil)
                    case .copyTextureToTexture(let s, _, _, _, _, let d, _, _, _):
                        note(s, read: true, write: nil); note(d, read: true, write: .full)
                    case .copyTextureSlices(let s, _, _, let d, _, _, _, _):
                        note(s, read: true, write: nil); note(d, read: true, write: .full)
                    case .generateMipmaps(let t): note(t, read: true, write: .full)
                    default: break
                    }
                }
            default: break
            }
        }
        return (Array(reads.values), Array(writes.values))
    }

    /// Copy regions between an image's level 0 / layer 0 and its surface
    /// memory, clipped so that no byte outside the surface is touched (the
    /// texture's texel size need not match the surface's), limited to
    /// `damage` (pixels of level 0).
    func surfaceRegions(_ image: VKImage, damage: SurfaceDamage = .full) -> [VkBufferImageCopy] {
        guard let s = image.surface else { return [] }
        let bpb = image.format.bytesPerBlock
        guard bpb > 0, s.bytesPerRow > 0 else { return [] }
        let aspect = image.format.isColor ? VK_IMAGE_ASPECT_COLOR_BIT.rawValue : image.format.viewAspect
        let sub = VkImageSubresourceLayers(aspectMask: aspect, mipLevel: 0, baseArrayLayer: 0, layerCount: 1)
        let width = min(s.width, s.bytesPerRow / bpb)
        guard width > 0, s.limit >= width * bpb else { return [] }
        let height = min(s.height, (s.limit - width * bpb) / s.bytesPerRow + 1)
        guard height > 0 else { return [] }
        // The damaged part, clipped to the surface (block-compressed formats: all of it).
        var x0 = 0, y0 = 0, x1 = width, y1 = height
        if !damage.isFull && image.format.blockWidth == 1 && image.format.blockHeight == 1 {
            guard !damage.isEmpty else { return [] }
            x0 = min(max(damage.x0, 0), width); x1 = min(max(damage.x1, x0), width)
            y0 = min(max(damage.y0, 0), height); y1 = min(max(damage.y1, y0), height)
            guard x1 > x0, y1 > y0 else { return [] }
        }
        // The buffer offset addresses the region's first texel, not the image's.
        let start = s.offset + y0 * s.bytesPerRow + x0 * bpb
        if s.bytesPerRow % bpb == 0 && start % lcm(4, bpb) == 0 {
            return [VkBufferImageCopy(bufferOffset: VkDeviceSize(start), bufferRowLength: UInt32(s.bytesPerRow / bpb),
                                      bufferImageHeight: UInt32(height), imageSubresource: sub,
                                      imageOffset: VkOffset3D(x: Int32(x0), y: Int32(y0), z: 0),
                                      imageExtent: VkExtent3D(width: UInt32(x1 - x0), height: UInt32(y1 - y0), depth: 1))]
        }
        // Pitch not a whole number of texels: one region per row (offsets must be texel-aligned).
        return (y0..<y1).compactMap { y -> VkBufferImageCopy? in
            let off = s.offset + y * s.bytesPerRow + x0 * bpb
            guard off % lcm(4, bpb) == 0 else { return nil }
            return VkBufferImageCopy(bufferOffset: VkDeviceSize(off), bufferRowLength: 0, bufferImageHeight: 0,
                                     imageSubresource: sub, imageOffset: VkOffset3D(x: Int32(x0), y: Int32(y), z: 0),
                                     imageExtent: VkExtent3D(width: UInt32(x1 - x0), height: 1, depth: 1))
        }
    }

    /// Whether the image already holds its surface's content: nothing wrote
    /// the surface since the image last copied it in or out (no other
    /// image's copy-out, no host write, and the surface's seed — raised by
    /// every CPU lock for writing — unchanged and no lock held now).
    func surfaceInSync(_ image: VKImage) -> Bool {
        guard options.surfaceSkipCopyIn, let s = image.surface, let gen = image.syncedGeneration,
              gen == surfaceGeneration(s), let seed = currentSeed(s) else { return false }
        return image.syncedSeed == seed
    }

    /// The surface's seed when no lock is held (nil: unknown or locked).
    func currentSeed(_ s: SurfaceLink) -> UInt32? {
        guard let st = s.syncState?(), !st.locked else { return nil }
        return st.seed
    }

    func surfaceGeneration(_ s: SurfaceLink) -> UInt64 { surfaceGenerations[s.syncKey] ?? 0 }

    /// Notes that the image and its surface hold the same pixels (after a copy in or out).
    func markSynced(_ image: VKImage) {
        guard let s = image.surface else { return }
        let seed = currentSeed(s)
        image.syncedGeneration = seed == nil ? nil : surfaceGeneration(s)
        image.syncedSeed = seed ?? 0
    }

    /// Something other than this image's copy-in wrote the surface's memory.
    func surfaceChanged(_ s: SurfaceLink) {
        surfaceGenerations[s.syncKey, default: 0] &+= 1
    }

    // MARK: - Replay

    func replay(_ mcb: MetalCommandBuffer, rec: inout Recording, sink: SubmitSink) throws {
        let tIn = profileClock()
        barrier(rec.cb)
        let (reads, writes) = surfaceUsage(mcb)
        if frameTrace != nil {
            sink.surfacesIn = reads.compactMap { $0.surface?.surfaceID }
            sink.surfacesOut = writes.compactMap { $0.0.surface?.surfaceID }
        }
        var copiedIn = false
        checkpoint(rec, pass: Self.checkpointPrologue, command: 0)
        for image in reads {
            if surfaceInSync(image) {
                statistics.surfaceUploadsSkipped += 1
                continue
            }
            var regions = surfaceRegions(image)
            guard let s = image.surface, !regions.isEmpty else { continue }
            fn.vkCmdCopyBufferToImage!(rec.cb, s.allocation.buffer.buffer, image.vkImage, VK_IMAGE_LAYOUT_GENERAL,
                                       UInt32(regions.count), &regions)
            statistics.surfaceUploads += 1
            statistics.surfaceBytesUp += s.bytesPerRow * Int(regions.reduce(0) { $0 + $1.imageExtent.height })
            markSynced(image)
            copiedIn = true
        }
        if copiedIn { barrier(rec.cb) }
        func segment(_ label: @autoclosure () -> String) {
            guard sink.traceSlot >= 0, let ft = frameTrace else { return }
            ft.segment(rec.cb, fn, slot: sink.traceSlot, &sink.segments, label())
        }
        if copiedIn { segment("in") }
        profiled(.surfacesIn, since: tIn)

        for (i, pass) in mcb.passes.enumerated() {
            if i > 0 { let tb = profileClock(); barrier(rec.cb); profiled(.barriers, since: tb) }
            checkpoint(rec, pass: i, command: Self.checkpointPassBegin)
            switch pass {
            case .render(let p):
                try replayRender(p, rec, passIndex: i)
                segment(passLabel(p))
            case .compute(let cmds):
                let tc = profileClock()
                try replayCompute(cmds, rec, passIndex: i)
                profiled(.compute, since: tc)
                segment("C\(cmds.reduce(0) { n, c in if case .dispatchThreadgroups = c { return n + 1 }; if case .dispatchThreads = c { return n + 1 }; return n })")
            case .blit(let cmds):
                let tb = profileClock()
                try replayBlit(cmds, rec, passIndex: i)
                profiled(.blit, since: tb)
                segment("B\(cmds.count)")
            case .event(let cmds):
                for c in cmds {
                    switch c {
                    case .wait(let h, let value):
                        guard let h, let e = events[h], let sem = e.semaphore else { noteSkip(); continue }
                        // The rest of the command buffer runs once the event
                        // reaches the value: held on the host when it has
                        // not yet (VulkanEventWaits.swift).
                        // A value already reached (and nothing held) needs nothing.
                        guard sink.holding || yvk_timeline_value(ctx, sem) < value else { continue }
                        let next = try newRecording()
                        yvk_cmd_memory_barrier(rec.cb, allCommands, memoryWrite, allCommands, memoryReadWrite)
                        sink.earlierDraws += rec.draws + rec.indirectDraws
                        try sinkSubmit(sink, rec, entry: nil)
                        _ = sinkWait(sink, sem, value: value)
                        rec = next
                        registerCheckpoints(rec, mcb)
                        barrier(rec.cb)
                    case .signal(let h, let value):
                        guard let h, let e = events[h], let sem = e.semaphore else { noteSkip(); continue }
                        guard value > e.highest else { continue }
                        e.highest = value
                        let next = try newRecording()
                        sink.earlierDraws += rec.draws + rec.indirectDraws
                        try sinkSubmit(sink, rec, entry: nil)
                        sinkSignal(sink, sem, value: value)
                        rec = next
                        registerCheckpoints(rec, mcb)
                        barrier(rec.cb)
                    case .unknown:
                        noteSkip()
                    }
                }
            case .unknown:
                noteSkip()
            }
        }

        let tOut = profileClock()
        defer { profiled(.surfacesOut, since: tOut) }
        if !writes.isEmpty {
            barrier(rec.cb)
            checkpoint(rec, pass: Self.checkpointPrologue, command: 1)
            for (image, damage) in writes {
                guard let s = image.surface else { continue }
                // Every other image of the surface no longer matches it.
                surfaceChanged(s)
                rec.writtenSurfaces.append(s.surfaceID)
                rec.writtenSurfaceKeys.append(s.syncKey)
                var regions = surfaceRegions(image, damage: damage)
                if !regions.isEmpty {
                    fn.vkCmdCopyImageToBuffer!(rec.cb, image.vkImage, VK_IMAGE_LAYOUT_GENERAL, s.allocation.buffer.buffer,
                                               UInt32(regions.count), &regions)
                    statistics.surfaceDownloads += 1
                    let rowBytes = Int(regions[0].imageExtent.width) * image.format.bytesPerBlock
                    statistics.surfaceBytesDown += rowBytes * Int(regions.reduce(0) { $0 + $1.imageExtent.height })
                    statistics.surfaceBytesDownFull += s.bytesPerRow * min(s.height, image.height)
                }
                markSynced(image)
            }
            if sink.traceSlot >= 0, let ft = frameTrace { ft.segment(rec.cb, fn, slot: sink.traceSlot, &sink.segments, "out") }
        }
        // Results (shared buffers, IOSurfaces) must be visible to the guest's CPU.
        yvk_cmd_memory_barrier(rec.cb, allCommands, memoryWrite, VK_PIPELINE_STAGE_2_HOST_BIT,
                               VK_ACCESS_2_HOST_READ_BIT | VK_ACCESS_2_HOST_WRITE_BIT)
    }

    /// A render pass in a trace segment label: R<width>x<height>[s<samples>]/<draws>[/L|C|D load][/resolve].
    func passLabel(_ p: MetalRenderPass) -> String {
        guard let d = p.descriptor else { return "R?" }
        let first = d.colorAttachments.first?.attachment ?? d.depth ?? d.stencil
        var size = "?"
        var samples = 1
        if let a = first, let h = a.texture, let t = textures[h] {
            let s = t.levelSize(a.level)
            size = "\(s.0)x\(s.1)"
            samples = t.image.samples
        }
        let draws = p.commands.reduce(0) { n, c in
            switch c {
            case .draw, .drawIndexed, .drawIndirect, .drawIndexedIndirect: return n + 1
            default: return n
            }
        }
        let load = first.map { $0.loadAction == MetalLoadAction.load ? "L" : ($0.loadAction == MetalLoadAction.clear ? "C" : "D") } ?? "-"
        let resolve = d.colorAttachments.contains { $0.resolveTexture != nil } ? "/res" : ""
        return "R\(size)" + (samples > 1 ? "s\(samples)" : "") + "/\(draws)/\(load)\(resolve)"
    }

    // MARK: Argument tables

    /// Writes a stage's argument table; returns its device address.
    func writeTable(_ b: StageBindings, _ statics: StageStatics, _ rec: Recording) throws -> UInt64 {
        let slice = try allocTransient(rec, YcodeMetalABI.tableSize, align: 64)
        let p = slice.pointer
        p.initializeMemory(as: UInt8.self, repeating: 0, count: YcodeMetalABI.tableSize)
        func put(_ entry: Int, _ v: UInt64) {
            if entry >= 0 && entry < YcodeMetalABI.tableEntries { p.storeBytes(of: v, toByteOffset: 8 * entry, as: UInt64.self) }
        }
        func buffer(_ i: Int) {
            guard let h = b.buffers[i].0 else { return }
            // An unknown handle (released, or never created) reads zeros instead of faulting.
            put(YcodeMetalABI.bufferEntry0 + i, buffers[h].map { $0.address + UInt64(b.buffers[i].1) } ?? dummyBufferAddress)
        }
        func texture(_ i: Int) {
            guard let h = b.textures[i], let t = textures[h] else { return }
            put(YcodeMetalABI.textureEntry0 + i, UInt64(textureOverride[h] ?? t.heapIndex))
        }
        let fast = options.recordFast
        if fast {
            forEachBit(b.bufferMask, buffer)
            forEachBit(b.textureMask.0, texture)
            forEachBit(b.textureMask.1, offset: 64, texture)
        } else {
            for i in 0..<b.buffers.count { buffer(i) }
            for i in 0..<b.textures.count { texture(i) }
        }
        for (i, s) in b.samplers.enumerated() where !fast || b.samplerMask & (1 << UInt16(i)) != 0 {
            guard let h = s.sampler, let smp = samplers[h] else { continue }
            var index = smp.heapIndex
            if s.lodMin != nil || s.lodMax != nil {
                var key = smp.key
                if let m = s.lodMin { key.lodMin = m }
                if let m = s.lodMax { key.lodMax = m }
                if let v = try? sampler(for: key) { index = v.heapIndex }
            }
            put(YcodeMetalABI.samplerEntry0 + i, UInt64(index))
        }
        for (entry, value) in statics.entries { put(entry, value) }
        return slice.address
    }

    /// The push constants: both tables and the kernel grid.
    func pushTables(_ cb: VkCommandBuffer?, _ a: UInt64, _ b: UInt64, grid: (Int, Int, Int) = (0, 0, 0)) {
        var pc: (UInt64, UInt64, UInt32, UInt32, UInt32, UInt32) =
            (a, b, UInt32(truncatingIfNeeded: grid.0), UInt32(truncatingIfNeeded: grid.1), UInt32(truncatingIfNeeded: grid.2), 0)
        fn.vkCmdPushConstants!(cb, ctx.pointee.pipelineLayout, VK_SHADER_STAGE_ALL.rawValue, 0,
                               UInt32(YcodeMetalABI.pushConstantBytes), &pc)
    }

    func bindHeap(_ rec: Recording, graphics: Bool) {
        if graphics ? rec.heapBoundGraphics : rec.heapBoundCompute { return }
        var set = ctx.pointee.heapSet
        fn.vkCmdBindDescriptorSets!(rec.cb, graphics ? VK_PIPELINE_BIND_POINT_GRAPHICS : VK_PIPELINE_BIND_POINT_COMPUTE,
                                    ctx.pointee.pipelineLayout, 0, 1, &set, 0, nil)
        if graphics { rec.heapBoundGraphics = true } else { rec.heapBoundCompute = true }
    }

    // MARK: Render passes

    func clearValue(_ metalFormat: UInt32, _ c: [Double]) -> VkClearValue {
        let v = c.count == 4 ? c : [0, 0, 0, 1]
        if MetalIntegerFormats.unsigned.contains(metalFormat) {
            return VkClearValue(color: VkClearColorValue(uint32: (UInt32(max(0, v[0])), UInt32(max(0, v[1])),
                                                                  UInt32(max(0, v[2])), UInt32(max(0, v[3])))))
        }
        if MetalIntegerFormats.signed.contains(metalFormat) {
            return VkClearValue(color: VkClearColorValue(int32: (Int32(v[0]), Int32(v[1]), Int32(v[2]), Int32(v[3]))))
        }
        return VkClearValue(color: VkClearColorValue(float32: (Float(v[0]), Float(v[1]), Float(v[2]), Float(v[3]))))
    }

    func loadOp(_ a: UInt16) -> VkAttachmentLoadOp {
        switch a {
        case MetalLoadAction.load: return VK_ATTACHMENT_LOAD_OP_LOAD
        case MetalLoadAction.clear: return VK_ATTACHMENT_LOAD_OP_CLEAR
        default: return VK_ATTACHMENT_LOAD_OP_DONT_CARE
        }
    }

    /// Store op and whether the attachment resolves.
    func storeOp(_ a: UInt16) -> (VkAttachmentStoreOp, Bool) {
        switch a {
        case 0: return (VK_ATTACHMENT_STORE_OP_DONT_CARE, false)
        case 2: return (VK_ATTACHMENT_STORE_OP_DONT_CARE, true)
        case 3: return (VK_ATTACHMENT_STORE_OP_STORE, true)
        default: return (VK_ATTACHMENT_STORE_OP_STORE, false)
        }
    }

    func replayRender(_ pass: MetalRenderPass, _ rec: Recording, passIndex: Int = 0) throws {
        let tBegin = profileClock()
        guard let d = pass.descriptor, d.hasAttachments else {
            // A pass without attachments (or without a begin record): nothing to render into.
            noteSkip()
            return
        }
        let cb = rec.cb
        var info = yvk_rendering_info()
        var width = d.renderTargetWidth, height = d.renderTargetHeight
        var sizeFromTexture: (Int, Int)?
        let integerFormats = MetalIntegerFormats.all

        func attachment(_ a: MetalRenderPassAttachment, clear: VkClearValue) -> (yvk_attachment, VKTexture)? {
            guard let h = a.texture, let tex = textures[h], let view = attachmentView(tex, level: a.level, slice: a.slice) else {
                return nil
            }
            let (store, resolve) = storeOp(a.storeAction)
            var out = yvk_attachment(view: view, resolveView: nil, resolveMode: VK_RESOLVE_MODE_NONE,
                                     load: loadOp(a.loadAction), store: store, clear: clear)
            if resolve, let rh = a.resolveTexture, let rt = textures[rh] {
                let lvl = a.openWords.count > 1 ? 0 : 0
                out.resolveView = attachmentView(rt, level: lvl, slice: 0)
                out.resolveMode = tex.format.isColor && !integerFormats.contains(tex.metalFormat)
                    ? VK_RESOLVE_MODE_AVERAGE_BIT : VK_RESOLVE_MODE_SAMPLE_ZERO_BIT
            }
            if sizeFromTexture == nil { let s = tex.levelSize(a.level); sizeFromTexture = (s.0, s.1) }
            return (out, tex)
        }

        var colorCount = 0
        // Color attachments a draw of this pass may also sample (§15.6):
        // image → the attachment texture. Only level 0, slice 0, stored, not resolved.
        var feedbackTargets: [ObjectIdentifier: VKTexture] = [:]
        var feedbackPossible = options.feedbackSnapshots
        withUnsafeMutableBytes(of: &info.color) { raw in
            let colors = raw.bindMemory(to: yvk_attachment.self)
            for c in d.colorAttachments where c.index >= 0 && c.index < Int(YVK_MAX_COLOR_ATTACHMENTS) {
                guard let tex = c.texture.flatMap({ textures[$0] }),
                      let (a, _) = attachment(c.attachment, clear: clearValue(tex.metalFormat, c.clearColor)) else { continue }
                colors[c.index] = a
                colorCount = max(colorCount, c.index + 1)
                if a.resolveView != nil || a.store != VK_ATTACHMENT_STORE_OP_STORE { feedbackPossible = false }
                if c.attachment.level == 0 && c.attachment.slice == 0 && tex.baseLevel == 0 && tex.image.samples == 1 {
                    feedbackTargets[ObjectIdentifier(tex.image)] = tex
                }
            }
        }
        if !feedbackPossible { feedbackTargets.removeAll() }
        info.colorCount = UInt32(YVK_MAX_COLOR_ATTACHMENTS)
        let dsClear = VkClearValue(depthStencil: VkClearDepthStencilValue(depth: Float(d.clearDepth), stencil: d.clearStencil))
        var hasDepth = false, hasStencil = false
        if let a = d.depth, let (att, tex) = attachment(a, clear: dsClear), tex.format.isDepth {
            info.depth = att
            hasDepth = true
            if let s = d.stencil, s.texture == a.texture, tex.format.isStencil {
                info.stencil = att
                info.stencil.load = loadOp(s.loadAction)
                info.stencil.store = storeOp(s.storeAction).0
                hasStencil = true
            }
        }
        if !hasStencil, let a = d.stencil, let (att, tex) = attachment(a, clear: dsClear), tex.format.isStencil {
            info.stencil = att
            hasStencil = true
        }
        guard colorCount > 0 || hasDepth || hasStencil else {
            noteSkip()
            return
        }
        if width <= 0 || height <= 0, let s = sizeFromTexture { (width, height) = s }
        if let s = sizeFromTexture { width = min(width, s.0); height = min(height, s.1) }
        guard width > 0, height > 0 else { noteSkip(); return }
        info.width = UInt32(width)
        info.height = UInt32(height)
        info.layerCount = 1
        yvk_cmd_begin_rendering(cb, &info)
        bindHeap(rec, graphics: true)

        // Default dynamic state (Metal's defaults for a new encoder).
        var vp = VkViewport(x: 0, y: Float(height), width: Float(width), height: -Float(height), minDepth: 0, maxDepth: 1)
        fn.vkCmdSetViewport!(cb, 0, 1, &vp)
        var scissor = VkRect2D(offset: VkOffset2D(x: 0, y: 0), extent: VkExtent2D(width: UInt32(width), height: UInt32(height)))
        fn.vkCmdSetScissor!(cb, 0, 1, &scissor)
        fn.vkCmdSetCullMode!(cb, VK_CULL_MODE_NONE.rawValue)
        fn.vkCmdSetFrontFace!(cb, vkFrontFace(0))
        fn.vkCmdSetPrimitiveTopology!(cb, VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST)
        fn.vkCmdSetPrimitiveRestartEnable!(cb, 0)
        fn.vkCmdSetDepthBiasEnable!(cb, 0)
        fn.vkCmdSetDepthBias!(cb, 0, 0, 0)
        var blend: [Float] = [0, 0, 0, 0]
        fn.vkCmdSetBlendConstants!(cb, &blend)
        let both = VK_STENCIL_FACE_FRONT_AND_BACK.rawValue
        fn.vkCmdSetStencilReference!(cb, both, 0)
        if let f = fn.vkCmdSetPolygonModeEXT { f(cb, VK_POLYGON_MODE_FILL) }
        if let f = fn.vkCmdSetDepthClampEnableEXT { f(cb, 0) }
        applyDepthStencil(nil, cb: cb, hasDepth: hasDepth, hasStencil: hasStencil)

        var vs = StageBindings(), fs = StageBindings()
        var pipeline: VKRenderPipeline?
        var tablePipeline: VKRenderPipeline?
        var bound: VkPipeline?
        var pushed: (UInt64, UInt64) = (0, 0)
        var topology: VkPrimitiveTopology = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST
        var restart = false
        var boundVertex: [Int: (VkBuffer?, Int)] = [:]

        func stage(_ s: MetalRenderStage) -> UnsafeMutablePointer<StageBindings> {
            s == .vertex ? withUnsafeMutablePointer(to: &vs) { $0 } : withUnsafeMutablePointer(to: &fs) { $0 }
        }

        /// A draw that samples a color attachment of this pass reads a copy
        /// of it made just before the draw (Metal's texture barrier: the
        /// draw sees the earlier draws' results). Sampling the attachment
        /// itself while rendering to it is a feedback loop Vulkan leaves
        /// undefined; on the Thor it hung the GPU (§15.6). Ends the
        /// rendering, copies, begins it again with every attachment loaded,
        /// and points the sampled slots at the copy. True when it did.
        var drawScissor: MetalScissorRect?
        func snapshotFeedback(_ p: VKRenderPipeline) throws -> Bool {
            var hits: [(MetalHandle, VKTexture)] = []
            for (stage, shader) in [(fs, p.fragment), (vs, p.vertex)] {
                for t in shader?.reflection.textures ?? [] where t.used != false && t.index >= 0 && t.index < stage.textures.count {
                    guard let h = stage.textures[t.index], let tex = textures[h],
                          let target = feedbackTargets[ObjectIdentifier(tex.image)],
                          tex.image.imageType == VK_IMAGE_TYPE_2D, tex.layerCount == 1 else { continue }
                    _ = target
                    hits.append((h, tex))
                }
            }
            guard !hits.isEmpty else {
                // Slots that pointed at an earlier copy point at their textures again.
                if !textureOverride.isEmpty { textureOverride.removeAll(); return true }
                return false
            }
            fn.vkCmdEndRendering!(cb)
            barrier(cb)
            var done: Set<ObjectIdentifier> = []
            for (h, tex) in hits {
                guard let copy = try feedbackCopy(of: tex, rec) else { continue }
                if done.insert(ObjectIdentifier(tex.image)).inserted {
                    let (w, hh, _) = tex.image.levelSize(0)
                    // Only the part the draw can write (its scissor rectangle,
                    // 2 texels wider for filtering): Core Animation reads the
                    // destination where it draws. Texels outside keep an older copy.
                    var x0 = 0, y0 = 0, x1 = w, y1 = hh
                    if let sc = drawScissor, !options.feedbackWholeLevel {
                        x0 = max(0, sc.x - 2); y0 = max(0, sc.y - 2)
                        x1 = min(w, sc.x + sc.width + 2); y1 = min(hh, sc.y + sc.height + 2)
                    }
                    if x1 > x0, y1 > y0 {
                        let aspect = VK_IMAGE_ASPECT_COLOR_BIT.rawValue
                        var region = VkImageCopy(
                            srcSubresource: VkImageSubresourceLayers(aspectMask: aspect, mipLevel: 0, baseArrayLayer: UInt32(tex.baseLayer), layerCount: 1),
                            srcOffset: VkOffset3D(x: Int32(x0), y: Int32(y0), z: 0),
                            dstSubresource: VkImageSubresourceLayers(aspectMask: aspect, mipLevel: 0, baseArrayLayer: 0, layerCount: 1),
                            dstOffset: VkOffset3D(x: Int32(x0), y: Int32(y0), z: 0),
                            extent: VkExtent3D(width: UInt32(x1 - x0), height: UInt32(y1 - y0), depth: 1))
                        fn.vkCmdCopyImage!(cb, tex.image.vkImage, VK_IMAGE_LAYOUT_GENERAL, copy.image.vkImage, VK_IMAGE_LAYOUT_GENERAL, 1, &region)
                        statistics.feedbackSnapshots += 1
                        statistics.feedbackTexels += (x1 - x0) * (y1 - y0)
                    }
                }
                textureOverride[h] = copy.heapIndex
            }
            barrier(cb)
            var again = info
            withUnsafeMutableBytes(of: &again.color) { raw in
                for i in 0..<Int(YVK_MAX_COLOR_ATTACHMENTS) { raw.bindMemory(to: yvk_attachment.self)[i].load = VK_ATTACHMENT_LOAD_OP_LOAD }
            }
            if again.depth.view != nil { again.depth.load = VK_ATTACHMENT_LOAD_OP_LOAD }
            if again.stencil.view != nil { again.stencil.load = VK_ATTACHMENT_LOAD_OP_LOAD }
            yvk_cmd_begin_rendering(cb, &again)
            return true
        }

        func prepareDraw(_ primitive: UInt32, indexed: Bool) throws -> Bool {
            let tp = profileClock()
            defer { profiled(.drawPrepare, since: tp) }
            if skipDraws { noteSkip(); return false }
            guard let p = pipeline, let vkp = renderVariant(p, topologyClass: topologyClass(ofPrimitive: primitive)) else {
                noteSkip()
                return false
            }
            if vkp != bound {
                fn.vkCmdBindPipeline!(cb, VK_PIPELINE_BIND_POINT_GRAPHICS, vkp)
                bound = vkp
            }
            for idx in p.vertexBufferIndices {
                guard idx < vs.buffers.count, let h = vs.buffers[idx].0, let b = buffers[h] else {
                    noteSkip()
                    return false
                }
                let off = b.offset + vs.buffers[idx].1
                if let cur = boundVertex[idx], cur.0 == b.vkBuffer, cur.1 == off { continue }
                var vb = b.vkBuffer
                var o = VkDeviceSize(off)
                fn.vkCmdBindVertexBuffers!(cb, UInt32(idx), 1, &vb, &o)
                boundVertex[idx] = (b.vkBuffer, off)
            }
            if p !== tablePipeline { vs.dirty = true; fs.dirty = true; tablePipeline = p }
            if !feedbackTargets.isEmpty, try snapshotFeedback(p) { vs.dirty = true; fs.dirty = true }
            let tt = profileClock()
            if vs.dirty { vs.table = try writeTable(vs, p.vertexStatics, rec); vs.dirty = false }
            if fs.dirty { fs.table = try writeTable(fs, p.fragmentStatics, rec); fs.dirty = false }
            profiled(.table, since: tt)
            if pushed != (vs.table, fs.table) {
                pushTables(cb, vs.table, fs.table)
                pushed = (vs.table, fs.table)
            }
            let t = vkTopology(primitive)
            if t != topology { fn.vkCmdSetPrimitiveTopology!(cb, t); topology = t }
            let wantRestart = indexed && (primitive == MetalPrimitiveType.lineStrip || primitive == MetalPrimitiveType.triangleStrip)
            if wantRestart != restart { fn.vkCmdSetPrimitiveRestartEnable!(cb, wantRestart ? 1 : 0); restart = wantRestart }
            statistics.draws += 1
            return true
        }

        profiled(.passBegin, since: tBegin)
        let tCommands = profileClock()
        let marks = checkpointsOn
        for (commandIndex, command) in pass.commands.enumerated() {
            if marks {
                switch command {
                case .draw, .drawIndexed, .drawIndirect, .drawIndexedIndirect: checkpoint(rec, pass: passIndex, command: commandIndex)
                default: break
                }
            }
            switch command {
            case .setRenderPipelineState(let h):
                pipeline = h.flatMap { renderPipelines[$0] }
                if !options.recordFast, let p = pipeline {
                    rec.noteShaders("\(shaderName(p.vertex))+\(shaderName(p.fragment))")
                }
            case .setDepthStencilState(let h):
                applyDepthStencil(h.flatMap { depthStencilStates[$0] }, cb: cb, hasDepth: hasDepth, hasStencil: hasStencil)
            case .setBuffer(let s, let index, let buffer, let offset):
                guard index >= 0 && index < YcodeMetalABI.bufferSlots else { continue }
                stage(s).pointee.setBuffer(index, buffer, offset)
                stage(s).pointee.dirty = true
            case .setBufferOffset(let s, let index, let offset):
                guard index >= 0 && index < YcodeMetalABI.bufferSlots else { continue }
                stage(s).pointee.buffers[index].1 = offset
                stage(s).pointee.dirty = true
            case .setTexture(let s, let index, let texture):
                guard index >= 0 && index < YcodeMetalABI.textureSlots else { continue }
                stage(s).pointee.setTexture(index, texture)
                stage(s).pointee.dirty = true
            case .setSamplerState(let s, let index, let sampler, let lodMin, let lodMax):
                guard index >= 0 && index < YcodeMetalABI.samplerSlots else { continue }
                stage(s).pointee.setSampler(index, SamplerBinding(sampler: sampler, lodMin: lodMin, lodMax: lodMax))
                stage(s).pointee.dirty = true
            case .setViewport(let v):
                guard v.width > 0, v.height != 0 else { continue }
                var vp = VkViewport(x: Float(v.x), y: Float(v.y + v.height), width: Float(v.width), height: -Float(v.height),
                                    minDepth: Float(min(max(v.znear, 0), 1)), maxDepth: Float(min(max(v.zfar, 0), 1)))
                fn.vkCmdSetViewport!(cb, 0, 1, &vp)
            case .setScissorRect(let r):
                drawScissor = r
                let x = min(max(r.x, 0), width), y = min(max(r.y, 0), height)
                var sc = VkRect2D(offset: VkOffset2D(x: Int32(x), y: Int32(y)),
                                  extent: VkExtent2D(width: UInt32(max(0, min(r.width, width - x))),
                                                     height: UInt32(max(0, min(r.height, height - y)))))
                fn.vkCmdSetScissor!(cb, 0, 1, &sc)
            case .setCullMode(let m):
                let mode: VkCullModeFlagBits = m == 1 ? VK_CULL_MODE_FRONT_BIT : (m == 2 ? VK_CULL_MODE_BACK_BIT : VK_CULL_MODE_NONE)
                fn.vkCmdSetCullMode!(cb, mode.rawValue)
            case .setFrontFacingWinding(let w):
                fn.vkCmdSetFrontFace!(cb, vkFrontFace(w))
            case .setTriangleFillMode(let m):
                if let f = fn.vkCmdSetPolygonModeEXT {
                    f(cb, m == 1 && ctx.pointee.features.fillModeNonSolid != 0 ? VK_POLYGON_MODE_LINE : VK_POLYGON_MODE_FILL)
                }
            case .setDepthClipMode(let m):
                if let f = fn.vkCmdSetDepthClampEnableEXT, ctx.pointee.features.depthClamp != 0 { f(cb, m == 1 ? 1 : 0) }
            case .setDepthBias(let bias, let slope, let clamp):
                fn.vkCmdSetDepthBiasEnable!(cb, bias != 0 || slope != 0 ? 1 : 0)
                fn.vkCmdSetDepthBias!(cb, bias, ctx.pointee.features.depthBiasClamp != 0 ? clamp : 0, slope)
            case .setBlendColor(let r, let g, let b, let a):
                var c: [Float] = [r, g, b, a]
                fn.vkCmdSetBlendConstants!(cb, &c)
            case .setStencilReference(let front, let back):
                fn.vkCmdSetStencilReference!(cb, VK_STENCIL_FACE_FRONT_BIT.rawValue, front)
                fn.vkCmdSetStencilReference!(cb, VK_STENCIL_FACE_BACK_BIT.rawValue, back)
            case .setColorStoreAction:
                break  // store actions are fixed when the pass begins (Store)
            case .draw(let dr):
                guard dr.vertexCount > 0, dr.instanceCount > 0, saneDraw(dr.vertexCount, dr.instanceCount),
                      try prepareDraw(dr.primitiveType, indexed: false) else { continue }
                rec.noteDraw(dr.vertexCount * dr.instanceCount)
                fn.vkCmdDraw!(cb, UInt32(dr.vertexCount), UInt32(dr.instanceCount), UInt32(dr.vertexStart), UInt32(dr.baseInstance))
            case .drawIndexed(let dr):
                // The indices must lie inside the index buffer (an index fetch past it reads whatever follows).
                guard dr.indexCount > 0, dr.instanceCount > 0, saneDraw(dr.indexCount, dr.instanceCount),
                      let ih = dr.indexBuffer, let ib = buffers[ih], dr.indexBufferOffset >= 0,
                      ib.offset + dr.indexBufferOffset + dr.indexCount * (dr.indexType == MetalIndexType.uint32 ? 4 : 2)
                          <= Int(ib.allocation.buffer.size) else {
                    noteSkip()
                    continue
                }
                guard try prepareDraw(dr.primitiveType, indexed: true) else { continue }
                fn.vkCmdBindIndexBuffer!(cb, ib.vkBuffer, VkDeviceSize(ib.offset + dr.indexBufferOffset),
                                         dr.indexType == MetalIndexType.uint32 ? VK_INDEX_TYPE_UINT32 : VK_INDEX_TYPE_UINT16)
                rec.noteDraw(dr.indexCount * dr.instanceCount)
                fn.vkCmdDrawIndexed!(cb, UInt32(dr.indexCount), UInt32(dr.instanceCount), 0, Int32(dr.baseVertex),
                                     UInt32(dr.baseInstance))
            case .drawIndirect(let primitive, let ih, let off):
                guard let ih, let b = buffers[ih], off >= 0, b.offset + off + 16 <= Int(b.allocation.buffer.size),
                      try prepareDraw(primitive, indexed: false) else { continue }
                rec.indirectDraws += 1
                fn.vkCmdDrawIndirect!(cb, b.vkBuffer, VkDeviceSize(b.offset + off), 1, 16)
            case .drawIndexedIndirect(let primitive, let indexType, let ixh, let ixOff, let ih, let off):
                guard let ixh, let ix = buffers[ixh], let ih, let b = buffers[ih], off >= 0,
                      b.offset + off + 20 <= Int(b.allocation.buffer.size), try prepareDraw(primitive, indexed: true) else {
                    continue
                }
                fn.vkCmdBindIndexBuffer!(cb, ix.vkBuffer, VkDeviceSize(ix.offset + ixOff),
                                         indexType == MetalIndexType.uint32 ? VK_INDEX_TYPE_UINT32 : VK_INDEX_TYPE_UINT16)
                rec.indirectDraws += 1
                fn.vkCmdDrawIndexedIndirect!(cb, b.vkBuffer, VkDeviceSize(b.offset + off), 1, 20)
            case .memoryBarrier, .useResources:
                break
            case .unknown:
                noteSkip()
            }
        }
        profiled(.renderCommands, since: tCommands)
        textureOverride.removeAll()
        let tEnd = profileClock()
        fn.vkCmdEndRendering!(cb)
        profiled(.passEnd, since: tEnd)
        _ = colorCount
    }

    /// A draw of more than `MetalCommandDecoder.largeDraw` vertices ×
    /// instances is skipped: such counts come only from records Ycode decodes
    /// wrongly, and the GPU would run the draw for minutes (on the Thor the
    /// driver then reports a context-switch timeout and every later
    /// submission is lost).
    func saneDraw(_ count: Int, _ instances: Int) -> Bool {
        let (work, overflow) = count.multipliedReportingOverflow(by: instances)
        guard overflow || work > MetalCommandDecoder.largeDraw else { return true }
        noteSkip()
        return false
    }

    /// Metal winding → Vulkan front face. With the negative viewport height
    /// Vulkan's framebuffer has the orientation of Metal's window
    /// coordinates, so clockwise stays clockwise.
    func vkFrontFace(_ metalWinding: UInt64) -> VkFrontFace {
        metalWinding == 1 ? VK_FRONT_FACE_COUNTER_CLOCKWISE : VK_FRONT_FACE_CLOCKWISE
    }

    func applyDepthStencil(_ d: MetalDepthStencilDescriptor?, cb: VkCommandBuffer?, hasDepth: Bool, hasStencil: Bool) {
        let ds = d ?? MetalDepthStencilDescriptor()
        let depthOn = hasDepth && (ds.depthCompareFunction != 7 || ds.depthWriteEnabled)
        fn.vkCmdSetDepthTestEnable!(cb, depthOn ? 1 : 0)
        fn.vkCmdSetDepthWriteEnable!(cb, hasDepth && ds.depthWriteEnabled ? 1 : 0)
        fn.vkCmdSetDepthCompareOp!(cb, vkCompare(ds.depthCompareFunction))
        let stencilOn = hasStencil && (ds.frontFaceStencil != nil || ds.backFaceStencil != nil)
        fn.vkCmdSetStencilTestEnable!(cb, stencilOn ? 1 : 0)
        let faces: [(VkStencilFaceFlagBits, MetalStencilDescriptor)] = [
            (VK_STENCIL_FACE_FRONT_BIT, ds.frontFaceStencil ?? MetalStencilDescriptor()),
            (VK_STENCIL_FACE_BACK_BIT, ds.backFaceStencil ?? ds.frontFaceStencil ?? MetalStencilDescriptor()),
        ]
        for (face, s) in faces {
            fn.vkCmdSetStencilOp!(cb, face.rawValue, vkStencilOp(s.stencilFailureOperation), vkStencilOp(s.depthStencilPassOperation),
                                  vkStencilOp(s.depthFailureOperation), vkCompare(s.compareFunction))
            fn.vkCmdSetStencilCompareMask!(cb, face.rawValue, s.readMask & 0xFF)
            fn.vkCmdSetStencilWriteMask!(cb, face.rawValue, s.writeMask & 0xFF)
        }
    }

    // MARK: Compute

    func replayCompute(_ commands: [MetalComputeCommand], _ rec: Recording, passIndex: Int = 0) throws {
        let cb = rec.cb
        bindHeap(rec, graphics: false)
        var b = StageBindings()
        var pipeline: VKComputePipeline?
        var bound: VkPipeline?
        var tgMemory: [Int: Int] = [:]

        func dispatch(groups: (Int, Int, Int), group: (Int, Int, Int), threads: (Int, Int, Int)?) throws {
            guard let p = pipeline else { noteSkip(); return }
            var groups = groups, group = group
            let t = threads ?? (groups.0 * group.0, groups.1 * group.1, groups.2 * group.2)
            if laneIsolated(p.shader), let iso = isolatedDispatch(threads: t) {
                (groups, group) = iso
                statistics.laneIsolatedDispatches += 1
            }
            let lengths = (p.shader?.reflection.compute?.threadgroupMemory?.slots ?? []).map { tgMemory[$0.index] ?? 0 }
            let key = ComputeVariantKey(x: max(group.0, 1), y: max(group.1, 1), z: max(group.2, 1), threadgroupMemory: lengths)
            guard let vkp = computeVariant(p, key) else { noteSkip(); return }
            if vkp != bound { fn.vkCmdBindPipeline!(cb, VK_PIPELINE_BIND_POINT_COMPUTE, vkp); bound = vkp }
            let table = try writeTable(b, p.statics, rec)
            pushTables(cb, table, 0, grid: t)
            fn.vkCmdDispatch!(cb, UInt32(groups.0), UInt32(groups.1), UInt32(groups.2))
            yvk_cmd_memory_barrier(cb, allCommands, memoryWrite, allCommands, memoryReadWrite)
            statistics.dispatches += 1
            if !options.recordFast, rec.dispatchNotes.count < 4 {
                rec.dispatchNotes.append(dispatchNote(b, groups: groups, group: group, threads: t))
            }
        }

        let marks = checkpointsOn
        for (commandIndex, command) in commands.enumerated() {
            if marks {
                switch command {
                case .dispatchThreadgroups, .dispatchThreads, .dispatchThreadgroupsIndirect:
                    checkpoint(rec, pass: passIndex, command: commandIndex)
                default: break
                }
            }
            switch command {
            case .setComputePipelineState(let h):
                pipeline = h.flatMap { computePipelines[$0] }
                if !options.recordFast, let p = pipeline { rec.noteShaders(shaderName(p.shader)) }
            case .setBuffer(let index, let buffer, let offset):
                guard index >= 0 && index < YcodeMetalABI.bufferSlots else { continue }
                b.setBuffer(index, buffer, offset)
            case .setBufferOffset(let index, let offset):
                guard index >= 0 && index < YcodeMetalABI.bufferSlots else { continue }
                b.buffers[index].1 = offset
            case .setTexture(let index, let texture):
                guard index >= 0 && index < YcodeMetalABI.textureSlots else { continue }
                b.setTexture(index, texture)
            case .setSamplerState(let index, let sampler, let lodMin, let lodMax):
                guard index >= 0 && index < YcodeMetalABI.samplerSlots else { continue }
                b.setSampler(index, SamplerBinding(sampler: sampler, lodMin: lodMin, lodMax: lodMax))
            case .setThreadgroupMemoryLength(let length, let index):
                tgMemory[index] = length
            case .setStageInRegion:
                noteSkip()
            case .dispatchThreadgroups(let g, let t):
                guard g.width > 0, g.height > 0, g.depth > 0 else { continue }
                try dispatch(groups: (g.width, g.height, g.depth), group: (t.width, t.height, t.depth), threads: nil)
            case .dispatchThreads(let n, let t):
                guard n.width > 0, n.height > 0, n.depth > 0 else { continue }
                let tw = max(t.width, 1), th = max(t.height, 1), td = max(t.depth, 1)
                try dispatch(groups: ((n.width + tw - 1) / tw, (n.height + th - 1) / th, (n.depth + td - 1) / td),
                             group: (tw, th, td), threads: (n.width, n.height, n.depth))
            case .dispatchThreadgroupsIndirect(let h, let offset, let t):
                guard let p = pipeline, let h, let buf = buffers[h] else { noteSkip(); continue }
                let lengths = (p.shader?.reflection.compute?.threadgroupMemory?.slots ?? []).map { tgMemory[$0.index] ?? 0 }
                guard let vkp = computeVariant(p, ComputeVariantKey(x: max(t.width, 1), y: max(t.height, 1), z: max(t.depth, 1),
                                                                    threadgroupMemory: lengths)) else { continue }
                if vkp != bound { fn.vkCmdBindPipeline!(cb, VK_PIPELINE_BIND_POINT_COMPUTE, vkp); bound = vkp }
                // The grid is in GPU memory; the shader's guard sees the largest value.
                let table = try writeTable(b, p.statics, rec)
                pushTables(cb, table, 0, grid: (Int(UInt32.max), Int(UInt32.max), Int(UInt32.max)))
                fn.vkCmdDispatchIndirect!(cb, buf.vkBuffer, VkDeviceSize(buf.offset + offset))
                yvk_cmd_memory_barrier(cb, allCommands, memoryWrite, allCommands, memoryReadWrite)
                statistics.dispatches += 1
            case .memoryBarrier, .memoryBarrierResources, .useResources:
                break  // every dispatch is followed by a full barrier
            case .unknown:
                noteSkip()
            }
        }
    }

    /// Diagnostics for a GPU hang: a dispatch's geometry and its buffers
    /// (length past the bound offset; the bytes of those of at most 64).
    func dispatchNote(_ b: StageBindings, groups: (Int, Int, Int), group: (Int, Int, Int), threads: (Int, Int, Int)) -> String {
        var parts: [String] = []
        for (i, (h, off)) in b.buffers.enumerated() {
            guard let h else { continue }
            guard let buf = buffers[h] else { parts.append("b\(i) unknown"); continue }
            let n = buf.length - off
            var text = "b\(i) \(n) B"
            if n > 0 && n <= 64, let p = buf.hostPointer {
                text += " " + (0..<n).map { String(format: "%02x", p.load(fromByteOffset: off + $0, as: UInt8.self)) }.joined()
            }
            parts.append(text)
        }
        return "dispatch \(groups.0)x\(groups.1)x\(groups.2) groups of \(group.0)x\(group.1)x\(group.2), grid "
            + "\(threads.0)x\(threads.1)x\(threads.2) [\(parts.joined(separator: ", "))]"
    }

    // MARK: Blit

    func replayBlit(_ commands: [MetalBlitCommand], _ rec: Recording, passIndex: Int = 0) throws {
        let cb = rec.cb
        for (i, command) in commands.enumerated() {
            if i > 0 { barrier(cb) }
            checkpoint(rec, pass: passIndex, command: i)
            switch command {
            case .copyBufferToBuffer(let s, let so, let d, let dO, let size):
                guard let s, let src = buffers[s], let d, let dst = buffers[d], size > 0, so >= 0, dO >= 0,
                      src.offset + so + size <= Int(src.allocation.buffer.size), dst.offset + dO + size <= Int(dst.allocation.buffer.size)
                else { noteSkip(); continue }
                var region = VkBufferCopy(srcOffset: VkDeviceSize(src.offset + so), dstOffset: VkDeviceSize(dst.offset + dO),
                                          size: VkDeviceSize(size))
                fn.vkCmdCopyBuffer!(cb, src.vkBuffer, dst.vkBuffer, 1, &region)
            case .copyBufferToTexture(let s, let so, let bpr, let bpi, let size, let d, let slice, let level, let origin, let options):
                guard let s, let src = buffers[s], let d, let tex = textures[d] else { noteSkip(); continue }
                var region = copyRegion(tex, level: level, slice: slice, origin: (origin.width, origin.height, origin.depth),
                                        size: (size.width, size.height, size.depth), bufferOffset: src.offset + so,
                                        bytesPerRow: bpr, bytesPerImage: bpi, options: options)
                guard copyIsValid(region, tex, level: level, bufferBytes: Int(src.allocation.buffer.size), what: "buffer → texture") else {
                    noteSkip(); continue
                }
                fn.vkCmdCopyBufferToImage!(cb, src.vkBuffer, tex.image.vkImage, VK_IMAGE_LAYOUT_GENERAL, 1, &region)
            case .copyTextureToBuffer(let s, let slice, let level, let origin, let size, let d, let dO, let bpr, let bpi, let options):
                guard let s, let tex = textures[s], let d, let dst = buffers[d] else { noteSkip(); continue }
                var region = copyRegion(tex, level: level, slice: slice, origin: (origin.width, origin.height, origin.depth),
                                        size: (size.width, size.height, size.depth), bufferOffset: dst.offset + dO,
                                        bytesPerRow: bpr, bytesPerImage: bpi, options: options)
                guard copyIsValid(region, tex, level: level, bufferBytes: Int(dst.allocation.buffer.size), what: "texture → buffer") else {
                    noteSkip(); continue
                }
                fn.vkCmdCopyImageToBuffer!(cb, tex.image.vkImage, VK_IMAGE_LAYOUT_GENERAL, dst.vkBuffer, 1, &region)
            case .copyTextureToTexture(let s, let ss, let sl, let so, let size, let d, let ds, let dl, let dO):
                guard let s, let src = textures[s], let d, let dst = textures[d] else { noteSkip(); continue }
                copyImage(cb, src, level: sl, slice: ss, origin: (so.width, so.height, so.depth), dst, level: dl, slice: ds,
                          origin: (dO.width, dO.height, dO.depth), size: (size.width, size.height, size.depth))
            case .copyTextureSlices(let s, let ss, let sl, let d, let ds, let dl, let sliceCount, let levelCount):
                guard let s, let src = textures[s], let d, let dst = textures[d] else { noteSkip(); continue }
                for l in 0..<max(levelCount, 1) {
                    let (w, h, dd) = src.levelSize(sl + l)
                    for k in 0..<max(sliceCount, 1) {
                        copyImage(cb, src, level: sl + l, slice: ss + k, origin: (0, 0, 0), dst, level: dl + l, slice: ds + k,
                                  origin: (0, 0, 0), size: (w, h, dd))
                    }
                }
            case .fillBuffer(let h, let location, let length, let value):
                guard let h, let b = buffers[h], length > 0, location >= 0,
                      b.offset + location + length <= Int(b.allocation.buffer.size) else { noteSkip(); continue }
                let byte = UInt8(truncatingIfNeeded: value)
                let start = b.offset + location
                if start % 4 == 0 && length % 4 == 0 {
                    fn.vkCmdFillBuffer!(cb, b.vkBuffer, VkDeviceSize(start), VkDeviceSize(length), UInt32(byte) * 0x0101_0101)
                } else {
                    let staging = try allocTransient(rec, length, align: 16)
                    staging.pointer.initializeMemory(as: UInt8.self, repeating: byte, count: length)
                    var region = VkBufferCopy(srcOffset: VkDeviceSize(staging.offset), dstOffset: VkDeviceSize(start),
                                              size: VkDeviceSize(length))
                    fn.vkCmdCopyBuffer!(cb, staging.vkBuffer, b.vkBuffer, 1, &region)
                }
            case .generateMipmaps(let h):
                guard let h, let tex = textures[h] else { noteSkip(); continue }
                generateMipmaps(cb, tex)
            case .optimizeContentsForGPUAccess, .updateFence, .waitForFence:
                continue
            case .unknown:
                noteSkip()
                continue
            }
            statistics.blits += 1
        }
    }

    /// Whether a buffer↔image copy is valid Vulkan usage and stays inside the
    /// buffer's `bufferBytes` (VkBufferImageCopy rules: a non-empty extent,
    /// row length and image height 0 or at least the extent, block-aligned
    /// offsets and lengths for compressed formats, a texel-aligned buffer
    /// offset). Invalid copies are undefined behaviour for the GPU (a copy
    /// engine may fault or hang); Metal's validation would have refused them,
    /// so they come only from records decoded wrongly or garbage arguments.
    /// Skipped and logged (the first 20; stage8-contract.md §15).
    func copyIsValid(_ r: VkBufferImageCopy, _ tex: VKTexture, level: Int, bufferBytes: Int, what: String) -> Bool {
        let f = tex.format
        let (aspect, bpb) = copyAspect(tex)
        let bw = f.blockWidth, bh = f.blockHeight
        let (lw, lh, _) = tex.levelSize(level)
        let w = Int(r.imageExtent.width), h = Int(r.imageExtent.height), d = Int(r.imageExtent.depth)
        let ox = Int(r.imageOffset.x), oy = Int(r.imageOffset.y)
        let rowTexels = r.bufferRowLength == 0 ? w : Int(r.bufferRowLength)
        let imageRows = r.bufferImageHeight == 0 ? h : Int(r.bufferImageHeight)
        var problem: String?
        if w <= 0 || h <= 0 || d <= 0 || bpb <= 0 {
            problem = "empty extent"
        } else if rowTexels < w || imageRows < h {
            problem = "row length \(r.bufferRowLength) or image height \(r.bufferImageHeight) below the extent"
        } else if bw > 1 || bh > 1,
                  rowTexels % bw != 0 || imageRows % bh != 0 || ox % bw != 0 || oy % bh != 0
                  || (w % bw != 0 && ox + w != lw) || (h % bh != 0 && oy + h != lh) {
            problem = "not aligned to the \(bw)x\(bh) blocks"
        } else if Int(r.bufferOffset) % (aspect == VK_IMAGE_ASPECT_COLOR_BIT.rawValue ? bpb : 4) != 0 {
            problem = "buffer offset \(r.bufferOffset) not aligned"
        } else {
            let rowBytes = (rowTexels + bw - 1) / bw * bpb
            let layerBytes = (imageRows + bh - 1) / bh * rowBytes
            let last = Int(r.bufferOffset) + (d - 1) * layerBytes + ((h + bh - 1) / bh - 1) * rowBytes + (w + bw - 1) / bw * bpb
            if last > bufferBytes { problem = "reaches byte \(last) of a \(bufferBytes)-byte buffer" }
        }
        guard let problem else { return true }
        if invalidCopyLogBudget > 0 {
            invalidCopyLogBudget -= 1
            log("skipped an invalid \(what) copy (\(problem)): texture \(tex.metalFormat) level \(level) size \(lw)x\(lh), "
                + "region \(ox),\(oy) \(w)x\(h)x\(d), buffer offset \(r.bufferOffset) row \(r.bufferRowLength) height \(r.bufferImageHeight)")
        }
        return false
    }

    /// The image a feedback snapshot of `tex` is copied into (one per format,
    /// size and swizzle, kept until shutdown), in GENERAL layout, with a
    /// sampled view like `tex`'s. Under the lock; `rec` gets the layout change.
    func feedbackCopy(of tex: VKTexture, _ rec: Recording) throws -> VKTexture? {
        let (w, h, _) = tex.image.levelSize(0)
        let s = tex.swizzle
        let key = "\(tex.image.format.format.rawValue)/\(tex.format.format.rawValue)/\(w)x\(h)/\(s.r.rawValue)\(s.g.rawValue)\(s.b.rawValue)\(s.a.rawValue)"
        if let t = feedbackCopies[key] { return t }
        let usage = VK_IMAGE_USAGE_SAMPLED_BIT.rawValue | VK_IMAGE_USAGE_TRANSFER_DST_BIT.rawValue
        var info = yvk_image_info(type: VK_IMAGE_TYPE_2D, format: tex.image.format.format, width: UInt32(w), height: UInt32(h), depth: 1,
                                  mipLevels: 1, arrayLayers: 1, samples: VK_SAMPLE_COUNT_1_BIT, usage: usage,
                                  flags: tex.format.format != tex.image.format.format ? VK_IMAGE_CREATE_MUTABLE_FORMAT_BIT.rawValue : 0)
        var img = yvk_image()
        var err = [CChar](repeating: 0, count: 256)
        guard yvk_image_create(ctx, &info, &img, &err, err.count) == 0 else {
            log("feedback copy image: \(cString(err))")
            return nil
        }
        let image = VKImage(image: img, format: tex.image.format, metalFormat: tex.image.metalFormat, imageType: VK_IMAGE_TYPE_2D,
                            width: w, height: h, depth: 1, levels: 1, layers: 1, samples: 1, usage: usage)
        yvk_cmd_image_layout(rec.cb, image.vkImage, image.format.aspect, VK_IMAGE_LAYOUT_UNDEFINED, VK_IMAGE_LAYOUT_GENERAL)
        image.initialized = true
        let t = VKTexture(image: image, format: tex.format, metalFormat: tex.metalFormat, textureType: MetalTextureType.type2D,
                          baseLevel: 0, levelCount: 1, baseLayer: 0, layerCount: 1, swizzle: tex.swizzle, metalUsage: MetalTextureUsage.shaderRead)
        makeShaderViews(t)
        guard t.heapIndex != 0 else { return nil }
        feedbackCopies[key] = t
        return t
    }

    func copyImage(_ cb: VkCommandBuffer?, _ src: VKTexture, level sl: Int, slice ss: Int, origin so: (Int, Int, Int),
                   _ dst: VKTexture, level dl: Int, slice ds: Int, origin dO: (Int, Int, Int), size: (Int, Int, Int)) {
        let s3 = src.image.imageType == VK_IMAGE_TYPE_3D, d3 = dst.image.imageType == VK_IMAGE_TYPE_3D
        let (sw, sh, sd) = src.levelSize(sl), (dw, dh, dd) = dst.levelSize(dl)
        let w = max(0, min(size.0, sw - so.0, dw - dO.0)), h = max(0, min(size.1, sh - so.1, dh - dO.1))
        let d = s3 || d3 ? max(0, min(size.2, sd - so.2, dd - dO.2)) : 1
        guard w > 0, h > 0, d > 0 else { return }
        let sa = src.format.isColor ? VK_IMAGE_ASPECT_COLOR_BIT.rawValue : src.format.aspect
        let da = dst.format.isColor ? VK_IMAGE_ASPECT_COLOR_BIT.rawValue : dst.format.aspect
        var region = VkImageCopy(
            srcSubresource: VkImageSubresourceLayers(aspectMask: sa, mipLevel: UInt32(src.baseLevel + sl),
                                                     baseArrayLayer: UInt32(s3 ? 0 : src.baseLayer + ss), layerCount: 1),
            srcOffset: VkOffset3D(x: Int32(so.0), y: Int32(so.1), z: Int32(s3 ? so.2 : 0)),
            dstSubresource: VkImageSubresourceLayers(aspectMask: da, mipLevel: UInt32(dst.baseLevel + dl),
                                                     baseArrayLayer: UInt32(d3 ? 0 : dst.baseLayer + ds), layerCount: 1),
            dstOffset: VkOffset3D(x: Int32(dO.0), y: Int32(dO.1), z: Int32(d3 ? dO.2 : 0)),
            extent: VkExtent3D(width: UInt32(w), height: UInt32(h), depth: UInt32(d)))
        fn.vkCmdCopyImage!(cb, src.image.vkImage, VK_IMAGE_LAYOUT_GENERAL, dst.image.vkImage, VK_IMAGE_LAYOUT_GENERAL, 1, &region)
    }

    func generateMipmaps(_ cb: VkCommandBuffer?, _ tex: VKTexture) {
        guard tex.levelCount > 1, tex.format.isColor else { return }
        let feats = yvk_format_features(ctx, tex.format.format)
        let linear = feats & VK_FORMAT_FEATURE_SAMPLED_IMAGE_FILTER_LINEAR_BIT.rawValue != 0
        let is3D = tex.image.imageType == VK_IMAGE_TYPE_3D
        for l in 1..<tex.levelCount {
            let (sw, sh, sd) = tex.levelSize(l - 1), (dw, dh, dd) = tex.levelSize(l)
            var blit = VkImageBlit(
                srcSubresource: VkImageSubresourceLayers(aspectMask: VK_IMAGE_ASPECT_COLOR_BIT.rawValue, mipLevel: UInt32(tex.baseLevel + l - 1),
                                                         baseArrayLayer: UInt32(tex.baseLayer), layerCount: UInt32(is3D ? 1 : tex.layerCount)),
                srcOffsets: (VkOffset3D(x: 0, y: 0, z: 0), VkOffset3D(x: Int32(sw), y: Int32(sh), z: Int32(sd))),
                dstSubresource: VkImageSubresourceLayers(aspectMask: VK_IMAGE_ASPECT_COLOR_BIT.rawValue, mipLevel: UInt32(tex.baseLevel + l),
                                                         baseArrayLayer: UInt32(tex.baseLayer), layerCount: UInt32(is3D ? 1 : tex.layerCount)),
                dstOffsets: (VkOffset3D(x: 0, y: 0, z: 0), VkOffset3D(x: Int32(dw), y: Int32(dh), z: Int32(dd))))
            fn.vkCmdBlitImage!(cb, tex.image.vkImage, VK_IMAGE_LAYOUT_GENERAL, tex.image.vkImage, VK_IMAGE_LAYOUT_GENERAL, 1, &blit,
                               linear ? VK_FILTER_LINEAR : VK_FILTER_NEAREST)
            yvk_cmd_memory_barrier(cb, VK_PIPELINE_STAGE_2_BLIT_BIT, VK_ACCESS_2_TRANSFER_WRITE_BIT, VK_PIPELINE_STAGE_2_BLIT_BIT,
                                   VK_ACCESS_2_TRANSFER_READ_BIT)
        }
    }
}
