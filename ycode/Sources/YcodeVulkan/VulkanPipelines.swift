// Shader translation and pipelines of VulkanMetalBackend.
//
// Pipeline creation is asynchronous: `createRenderPipeline` and
// `createComputePipeline` record the pipeline and return at once (the guest
// only needs a ref, and creation failures are never reported to it,
// metal-sim-protocol.md §12 item 7); translation (`ycode-airc`, ~0.4 s for
// QuartzCore's uber-shaders) and the first Vulkan compile (several seconds
// cold for those on the Thor) run on `compileQueue`. A submission first
// waits, outside the backend lock, for the pipelines it uses and compiles
// the compute variants it needs (`preparePipelines`). Every compile goes
// through one VkPipelineCache, loaded from and saved to
// `Options.pipelineCachePath`.

import CVulkan
import Foundation
import YcodeMetalHost

extension VulkanMetalBackend {
    // MARK: - Translation

    /// Translates through the backend's cache (`useCache` false: always ask the translator).
    func translate(_ request: TranslationRequest, useCache: Bool = true) throws -> TranslatedShader {
        let key = TranslationKey(hash: fnv1a64(request.metallib), count: request.metallib.count,
                                 linked: request.linkVertexHash.map { fnv1a64(Array($0.utf8)) } ?? 0,
                                 linkedCount: request.linkVertexHash?.count ?? -1)
        if useCache {
            translationLock.lock()
            if let t = translations[key] {
                translationLock.unlock()
                cond.lock(); statistics.translationHits += 1; cond.unlock()
                return t
            }
            translationLock.unlock()
        }
        guard let translator else { throw VulkanBackendError("no shader translator (ycode-airc not found)") }
        let start = DispatchTime.now().uptimeNanoseconds
        defer {
            let ns = DispatchTime.now().uptimeNanoseconds &- start
            cond.lock(); statistics.translations.add(ns); cond.unlock()
        }
        let t = try translator.translate(request)
        translationLock.lock()
        translations[key] = t
        translationLock.unlock()
        return t
    }

    /// Runs `work` on the compile queue, or now when pipelines are synchronous.
    func schedule(_ work: @escaping @Sendable () -> Void) {
        if options.asynchronousPipelines {
            compileQueue.addOperation(work)
        } else {
            work()
        }
    }

    // MARK: - Render pipelines

    public func createRenderPipeline(_ handle: MetalHandle, _ desc: MetalRenderPipelineDescriptor) throws {
        guard isAvailable else { throw VulkanBackendError("no GPU") }
        let p = VKRenderPipeline(desc: desc)
        p.ready.enter()
        cond.lock()
        let vf = desc.vertexFunction.flatMap { functions[$0] }
        let ff = desc.fragmentFunction.flatMap { functions[$0] }
        if let old = renderPipelines[handle] { releaseRenderPipeline(old) }
        renderPipelines[handle] = p
        statistics.renderPipelines += 1
        cond.unlock()
        let failure = FailureBox()
        schedule { [self] in
            defer { p.ready.leave() }
            do {
                try buildRenderPipeline(p, handle: handle, vf: vf, ff: ff)
            } catch {
                log("render pipeline \(handle) (\(desc.label ?? "unlabelled")): \(error)")
                cond.lock(); p.broken = true; cond.unlock()
                failure.error = error
            }
        }
        if !options.asynchronousPipelines, let e = failure.error { throw e }
    }

    func buildRenderPipeline(_ p: VKRenderPipeline, handle: MetalHandle, vf: VKFunction?, ff: VKFunction?) throws {
        var vf = vf, ff = ff
        guard vf != nil || ff != nil else { throw VulkanBackendError("render pipeline without known functions") }
        // The stage comes from the translator's reflection: if the
        // descriptor's two function fields arrive the other way round, swap them.
        var vs = try vf.map { try translate(TranslationRequest(metallib: $0.metallib)) }
        if vs?.reflection.stage == .fragment || (vs == nil && ff != nil) {
            swap(&vf, &ff)
            vs = try vf.map { try translate(TranslationRequest(metallib: $0.metallib)) }
            if vs != nil { log("render pipeline \(handle): vertex and fragment functions arrived swapped; using them by stage") }
        }
        guard let vfn = vf, let vs, vs.reflection.stage == .vertex else {
            throw VulkanBackendError("no vertex function")
        }
        var fs: TranslatedShader?
        if let ff {
            // Same affinity as the vertex function: the same translator process links them.
            let affinity = fnv1a64(vfn.metallib)
            let request = TranslationRequest(metallib: ff.metallib, linkVertexHash: vs.reflection.hash, affinity: affinity)
            do {
                fs = try translate(request)
            } catch let e as ShaderTranslationError where e.description.contains("link_vertex") {
                // That process has not seen the vertex function (restarted, or
                // the vertex translation came from the cache): show it again.
                _ = try translate(TranslationRequest(metallib: vfn.metallib, affinity: affinity), useCache: false)
                fs = try translate(request)
            }
        }
        cond.lock()
        let setup = Result { try setUpRenderPipeline(p, vertex: vs, fragment: fs) }
        cond.unlock()
        try setup.get()
        let cls = p.desc.inputPrimitiveTopology != 0 ? p.desc.inputPrimitiveTopology : 3
        let start = Date()
        let pipe = compileRenderVariant(p, topologyClass: cls)
        let seconds = Date().timeIntervalSince(start)
        if seconds > 1 { log("render pipeline \(handle) (\(p.desc.label ?? "unlabelled")): compiled in \(String(format: "%.2f", seconds)) s") }
        cond.lock()
        defer { cond.unlock() }
        guard let pipe else {
            p.failed.insert(cls)
            throw VulkanBackendError("Vulkan pipeline creation failed")
        }
        pipelineCacheDirty = true
        if p.released {
            fn.vkDestroyPipeline!(ctx.pointee.device, pipe, nil)  // never used by the GPU
        } else {
            p.variants[cls] = pipe
        }
    }

    /// Vertex input, attachments and blend state, constant data and
    /// constexpr samplers. Under the lock.
    func setUpRenderPipeline(_ p: VKRenderPipeline, vertex vs: TranslatedShader, fragment fs: TranslatedShader?) throws {
        guard !p.released else { throw VulkanBackendError("released while building") }
        let desc = p.desc
        var info = yvk_graphics_info()
        // Vertex input (Location n = attribute n; binding = Metal buffer index).
        var vertexIndices: [Int] = []
        if let vd = desc.vertexDescriptor {
            var attrs: [VkVertexInputAttributeDescription] = []
            for a in vd.attributes where a.format != 0 {
                guard let f = metalVertexFormat(a.format) else { throw VulkanBackendError("vertex format \(a.format)") }
                attrs.append(VkVertexInputAttributeDescription(location: UInt32(a.index), binding: UInt32(a.bufferIndex),
                                                               format: f, offset: UInt32(a.offset)))
            }
            var binds: [yvk_vertex_binding] = []
            for idx in Set(attrs.map { Int($0.binding) }).sorted() {
                let l = vd.layouts.first { $0.bufferIndex == idx } ?? MetalVertexDescriptor.Layout(bufferIndex: idx)
                switch l.stepFunction {
                case 0:  // constant: every vertex reads element 0
                    binds.append(yvk_vertex_binding(binding: UInt32(idx), stride: 0, inputRate: VK_VERTEX_INPUT_RATE_VERTEX, divisor: 1))
                case 2:
                    binds.append(yvk_vertex_binding(binding: UInt32(idx), stride: UInt32(l.stride),
                                                    inputRate: VK_VERTEX_INPUT_RATE_INSTANCE, divisor: UInt32(max(l.stepRate, 1))))
                default:
                    binds.append(yvk_vertex_binding(binding: UInt32(idx), stride: UInt32(l.stride),
                                                    inputRate: VK_VERTEX_INPUT_RATE_VERTEX, divisor: 1))
                }
                vertexIndices.append(idx)
            }
            info.attributeCount = UInt32(min(attrs.count, 32))
            info.bindingCount = UInt32(min(binds.count, 32))
            withUnsafeMutableBytes(of: &info.attributes) { raw in
                let q = raw.bindMemory(to: VkVertexInputAttributeDescription.self)
                for (i, a) in attrs.prefix(32).enumerated() { q[i] = a }
            }
            withUnsafeMutableBytes(of: &info.bindings) { raw in
                let q = raw.bindMemory(to: yvk_vertex_binding.self)
                for (i, b) in binds.prefix(32).enumerated() { q[i] = b }
            }
        }
        info.samples = VkSampleCountFlagBits(rawValue: UInt32(max(desc.rasterSampleCount, 1)))
        info.alphaToCoverage = desc.alphaToCoverageEnabled ? 1 : 0
        info.colorCount = UInt32(YVK_MAX_COLOR_ATTACHMENTS)
        withUnsafeMutableBytes(of: &info.colorFormats) { rawF in
            withUnsafeMutableBytes(of: &info.blend) { rawB in
                let formats = rawF.bindMemory(to: VkFormat.self)
                let blends = rawB.bindMemory(to: VkPipelineColorBlendAttachmentState.self)
                for i in 0..<Int(YVK_MAX_COLOR_ATTACHMENTS) {
                    formats[i] = VK_FORMAT_UNDEFINED
                    blends[i] = VkPipelineColorBlendAttachmentState()
                }
                for c in desc.colorAttachments where c.index >= 0 && c.index < Int(YVK_MAX_COLOR_ATTACHMENTS) && c.pixelFormat != 0 {
                    guard let f = resolveFormat(c.pixelFormat) else { continue }
                    formats[c.index] = f.format
                    blends[c.index] = VkPipelineColorBlendAttachmentState(
                        blendEnable: c.blendingEnabled ? 1 : 0,
                        srcColorBlendFactor: vkBlendFactor(c.sourceRGBBlendFactor),
                        dstColorBlendFactor: vkBlendFactor(c.destinationRGBBlendFactor),
                        colorBlendOp: vkBlendOp(c.rgbBlendOperation),
                        srcAlphaBlendFactor: vkBlendFactor(c.sourceAlphaBlendFactor),
                        dstAlphaBlendFactor: vkBlendFactor(c.destinationAlphaBlendFactor),
                        alphaBlendOp: vkBlendOp(c.alphaBlendOperation),
                        colorWriteMask: vkColorWriteMask(c.writeMask))
                }
            }
        }
        let depthFormat = desc.depthAttachmentPixelFormat != 0
            ? (resolveFormat(desc.depthAttachmentPixelFormat).flatMap { $0.isDepth ? $0.format : nil } ?? VK_FORMAT_UNDEFINED)
            : VK_FORMAT_UNDEFINED
        let stencilFormat = desc.stencilAttachmentPixelFormat != 0
            ? (resolveFormat(desc.stencilAttachmentPixelFormat).flatMap { $0.isStencil ? $0.format : nil } ?? VK_FORMAT_UNDEFINED)
            : VK_FORMAT_UNDEFINED
        info.depthFormat = depthFormat
        info.stencilFormat = stencilFormat
        p.vertexStatics = try statics(for: vs.reflection)
        if let fs {
            do {
                p.fragmentStatics = try statics(for: fs.reflection)
            } catch {
                for a in p.vertexStatics.memory { releaseAllocationReference(a) }
                p.vertexStatics = StageStatics()
                throw error
            }
        }
        p.info = info
        p.vertexBufferIndices = vertexIndices
        p.depthFormat = depthFormat
        p.stencilFormat = stencilFormat
        p.vertex = vs
        p.fragment = fs
    }

    /// The fixed argument-table entries of a function: its constant data
    /// (copied once into GPU-visible memory) and its constexpr samplers. Under the lock.
    func statics(for r: ShaderReflection) throws -> StageStatics {
        var out = StageStatics()
        if let c = r.constantData {
            let bytes = c.bytes
            var b = yvk_buffer()
            var err = [CChar](repeating: 0, count: 256)
            guard yvk_buffer_create(ctx, VkDeviceSize(max(bytes.count, 16)), YVK_MEMORY_HOST, nil, &b, &err, err.count) == 0,
                  let q = b.mapped else { throw VulkanBackendError("constant data: \(cString(err))") }
            bytes.withUnsafeBytes { if let base = $0.baseAddress { q.copyMemory(from: base, byteCount: bytes.count) } }
            let a = VKAllocation(buffer: b, base: q, key: nil, owner: nil)
            a.references = 1
            out.memory.append(a)
            out.entries.append((c.tableEntry ?? YcodeMetalABI.constantDataEntry, b.address))
        }
        for c in r.constexprSamplers ?? [] {
            let s = try sampler(for: SamplerKey(c))
            out.entries.append((c.tableEntry, UInt64(s.heapIndex)))
        }
        return out
    }

    /// Compiles one topology class of a built pipeline. Needs no lock: it
    /// reads fields that do not change after setup.
    func compileRenderVariant(_ p: VKRenderPipeline, topologyClass cls: UInt32, locked: Bool = false) -> VkPipeline? {
        let start = DispatchTime.now().uptimeNanoseconds
        let result = compileRenderVariantTimed(p, topologyClass: cls)
        let ns = DispatchTime.now().uptimeNanoseconds &- start
        if locked { statistics.renderCompiles.add(ns) } else { cond.lock(); statistics.renderCompiles.add(ns); cond.unlock() }
        let ms = Double(ns) / 1e6
        if verbose { log("compile render \(p.desc.label ?? "unlabelled") class \(cls): \(String(format: "%.1f", ms)) ms") }
        return result
    }

    func compileRenderVariantTimed(_ p: VKRenderPipeline, topologyClass cls: UInt32) -> VkPipeline? {
        guard let vertex = p.vertex else { return nil }
        if usesPipelineLibraries { return linkRenderVariant(p, vertex: vertex, topologyClass: cls) }
        var info = p.info
        info.topology = vkTopology(forClass: cls)
        var err = [CChar](repeating: 0, count: 512)
        let vsEntry = vertex.reflection.entryPoint ?? "main"
        let fsEntry = p.fragment?.reflection.entryPoint ?? "main"
        let fsCode = p.fragment?.spirv ?? []
        let hasFragment = p.fragment != nil
        let result: VkPipeline? = vertex.spirv.withUnsafeBufferPointer { vsWords in
            fsCode.withUnsafeBufferPointer { fsWords in
                vsEntry.withCString { vsName in
                    fsEntry.withCString { fsName in
                        info.vertex = yvk_shader_stage(code: vsWords.baseAddress, wordCount: vsWords.count, entry: vsName,
                                                       constants: nil, constantCount: 0, flags: 0)
                        info.fragment = hasFragment
                            ? yvk_shader_stage(code: fsWords.baseAddress, wordCount: fsWords.count, entry: fsName,
                                               constants: nil, constantCount: 0, flags: 0)
                            : yvk_shader_stage()
                        return yvk_graphics_pipeline_create(ctx, &info, &err, err.count)
                    }
                }
            }
        }
        if result == nil { log("render pipeline (\(p.desc.label ?? "unlabelled"), class \(cls)): \(cString(err))") }
        return result
    }

    /// The Vulkan pipeline for a topology class, compiled on first use. Under the lock.
    func renderVariant(_ p: VKRenderPipeline, topologyClass cls: UInt32) -> VkPipeline? {
        guard p.isBuilt else { return nil }
        if let v = p.variants[cls] { return v }
        if p.failed.contains(cls) { return nil }
        guard let pipe = compileRenderVariant(p, topologyClass: cls, locked: true) else {
            p.failed.insert(cls)
            return nil
        }
        pipelineCacheDirty = true
        p.variants[cls] = pipe
        return pipe
    }

    // MARK: - Compute pipelines

    public func createComputePipeline(_ handle: MetalHandle, function: MetalHandle) throws -> MetalComputePipelineInfo {
        guard isAvailable else { throw VulkanBackendError("no GPU") }
        let p = VKComputePipeline()
        p.ready.enter()
        cond.lock()
        let f = functions[function]
        if let old = computePipelines[handle] { releaseComputePipeline(old) }
        computePipelines[handle] = p
        statistics.computePipelines += 1
        cond.unlock()
        let failure = FailureBox()
        schedule { [self] in
            defer { p.ready.leave() }
            do {
                guard let f else { throw VulkanBackendError("unknown function \(function)") }
                let shader = try translate(TranslationRequest(metallib: f.metallib))
                guard shader.reflection.stage == .kernel else { throw VulkanBackendError("not a kernel") }
                cond.lock()
                defer { cond.unlock() }
                guard !p.released else { return }
                p.statics = try statics(for: shader.reflection)
                p.shader = shader
            } catch {
                log("compute pipeline \(handle): \(error)")
                cond.lock(); p.broken = true; cond.unlock()
                failure.error = error
            }
        }
        if !options.asynchronousPipelines, let e = failure.error { throw e }
        let maxInv = Int(min(ctx.pointee.properties.limits.maxComputeWorkGroupInvocations, 1024))
        return MetalComputePipelineInfo(maxTotalThreadsPerThreadgroup: UInt16(maxInv),
                                        threadExecutionWidth: UInt16(max(ctx.pointee.subgroupSize, 1)))
    }

    /// Compiles one compute variant. Needs no lock.
    func compileComputeVariant(_ shader: TranslatedShader, _ key: ComputeVariantKey, locked: Bool = false) -> VkPipeline? {
        let start = DispatchTime.now().uptimeNanoseconds
        defer {
            let ns = DispatchTime.now().uptimeNanoseconds &- start
            if locked { statistics.computeCompiles.add(ns) } else { cond.lock(); statistics.computeCompiles.add(ns); cond.unlock() }
        }
        let r = shader.reflection
        var constants: [yvk_spec_constant] = []
        let ids = r.compute?.workgroupSizeSpecIds ?? YcodeMetalABI.specWorkgroup
        for (i, v) in [key.x, key.y, key.z].enumerated() where i < ids.count {
            constants.append(yvk_spec_constant(id: ids[i], value: UInt32(v)))
        }
        // Threadgroup memory: [[threadgroup(n)]] slots after the static part,
        // 16-byte aligned, lengths from setThreadgroupMemoryLength (key order = slots order).
        if let tg = r.compute?.threadgroupMemory, tg.dynamic == true {
            var offset = tg.slotsBase ?? roundUp(tg.staticBytes ?? 0, 16)
            for (i, slot) in (tg.slots ?? []).enumerated() {
                if let id = slot.offsetSpecId { constants.append(yvk_spec_constant(id: id, value: UInt32(offset))) }
                offset += roundUp(max(i < key.threadgroupMemory.count ? key.threadgroupMemory[i] : 0, 16), 16)
            }
            constants.append(yvk_spec_constant(id: tg.sizeSpecId ?? YcodeMetalABI.specThreadgroupBytes, value: UInt32(offset)))
        }
        var flags: UInt32 = 0
        let sg = Int(ctx.pointee.subgroupSize)
        if ctx.pointee.features.computeFullSubgroups != 0 && sg > 0 && key.x % sg == 0 {
            flags |= VK_PIPELINE_SHADER_STAGE_CREATE_REQUIRE_FULL_SUBGROUPS_BIT.rawValue
        }
        var err = [CChar](repeating: 0, count: 512)
        let entry = r.entryPoint ?? "main"
        let pipe: VkPipeline? = shader.spirv.withUnsafeBufferPointer { words in
            entry.withCString { name in
                constants.withUnsafeBufferPointer { c in
                    var stage = yvk_shader_stage(code: words.baseAddress, wordCount: words.count, entry: name,
                                                 constants: c.baseAddress, constantCount: UInt32(c.count), flags: flags)
                    return yvk_compute_pipeline_create(ctx, &stage, &err, err.count)
                }
            }
        }
        if pipe == nil { log("compute pipeline \(r.entryPoint ?? ""): \(cString(err))") }
        return pipe
    }

    /// The compute variant, compiled on first use. Under the lock.
    func computeVariant(_ p: VKComputePipeline, _ key: ComputeVariantKey) -> VkPipeline? {
        guard let shader = p.shader, !p.broken else { return nil }
        if let v = p.variants[key] { return v }
        if p.failed.contains(key) { return nil }
        guard let pipe = compileComputeVariant(shader, key, locked: true) else {
            p.failed.insert(key)
            return nil
        }
        pipelineCacheDirty = true
        p.variants[key] = pipe
        return pipe
    }

    // MARK: - Lane-isolated kernels (§15.5)

    /// Whether a kernel runs one thread per workgroup: it is named in
    /// `Options.laneIsolatedKernels` and its result cannot depend on the
    /// workgroup shape (it reads only grid-wide built-ins, has no
    /// threadgroup memory and no barriers or subgroup operations).
    func laneIsolated(_ shader: TranslatedShader?) -> Bool {
        guard let r = shader?.reflection, r.stage == .kernel, let name = r.entryPoint,
              options.laneIsolatedKernels.contains(name) else { return false }
        let gridOnly: Set<String> = ["thread_position_in_grid", "threads_per_grid"]
        guard Set(r.builtins ?? []).isSubset(of: gridOnly) else { return false }
        let used = Set(r.uses ?? [])
        if used.contains("barrier") || used.contains(where: { $0.contains("simd") || $0.contains("quad") }) { return false }
        if let tg = r.compute?.threadgroupMemory, (tg.staticBytes ?? 0) > 0 || tg.dynamic == true || !(tg.slots ?? []).isEmpty {
            return false
        }
        return true
    }

    /// A dispatch as recorded: workgroups and workgroup size, with the
    /// threads of the grid (lane-isolated kernels get one thread per
    /// workgroup; nil when they cannot, e.g. too many workgroups).
    func isolatedDispatch(threads t: (Int, Int, Int)) -> (groups: (Int, Int, Int), group: (Int, Int, Int))? {
        let l = ctx.pointee.properties.limits
        guard t.0 > 0, t.1 > 0, t.2 > 0, t.0 <= Int(l.maxComputeWorkGroupCount.0), t.1 <= Int(l.maxComputeWorkGroupCount.1),
              t.2 <= Int(l.maxComputeWorkGroupCount.2) else { return nil }
        return (t, (1, 1, 1))
    }

    // MARK: - Before a submission

    /// Waits (outside the lock) for the pipelines a command buffer uses and
    /// compiles the compute variants its dispatches need, so that recording
    /// under the lock never waits for a translation or a cold compile.
    func preparePipelines(_ mcb: MetalCommandBuffer) {
        var renders: [VKRenderPipeline] = []
        // (pipeline, workgroup size, threadgroup memory lengths, the lane-isolated variant)
        var dispatches: [(VKComputePipeline, (Int, Int, Int), [Int: Int], Bool)] = []
        cond.lock()
        for pass in mcb.passes {
            switch pass {
            case .render(let rp):
                for case .setRenderPipelineState(let h?) in rp.commands {
                    if let p = renderPipelines[h], !renders.contains(where: { $0 === p }) { renders.append(p) }
                }
            case .compute(let cmds):
                var current: VKComputePipeline?
                var tg: [Int: Int] = [:]
                for c in cmds {
                    switch c {
                    case .setComputePipelineState(let h): current = h.flatMap { computePipelines[$0] }
                    case .setThreadgroupMemoryLength(let n, let index): tg[index] = n
                    case .dispatchThreadgroups(_, let t), .dispatchThreads(_, let t):
                        if let p = current {
                            dispatches.append((p, (max(t.width, 1), max(t.height, 1), max(t.depth, 1)), tg, false))
                            dispatches.append((p, (1, 1, 1), tg, true))
                        }
                    case .dispatchThreadgroupsIndirect(_, _, let t):
                        if let p = current { dispatches.append((p, (max(t.width, 1), max(t.height, 1), max(t.depth, 1)), tg, false)) }
                    default: break
                    }
                }
            default: break
            }
        }
        cond.unlock()
        let waitStart = DispatchTime.now().uptimeNanoseconds
        defer {
            let ns = DispatchTime.now().uptimeNanoseconds &- waitStart
            if ns > 1_000_000 { cond.lock(); statistics.pipelineWaits.add(ns); cond.unlock() }
        }
        let deadline = DispatchTime.now() + 120
        for p in renders where p.ready.wait(timeout: deadline) == .timedOut { log("a render pipeline is still building after 120 s") }
        for (p, _, _, _) in dispatches where p.ready.wait(timeout: deadline) == .timedOut { log("a compute pipeline is still building") }
        for (p, size, tg, isolatedVariant) in dispatches {
            cond.lock()
            let shader = p.shader
            let lengths = (shader?.reflection.compute?.threadgroupMemory?.slots ?? []).map { tg[$0.index] ?? 0 }
            let key = ComputeVariantKey(x: size.0, y: size.1, z: size.2, threadgroupMemory: lengths)
            let needed = shader != nil && !p.broken && p.variants[key] == nil && !p.failed.contains(key)
                && (!isolatedVariant || laneIsolated(shader))
            cond.unlock()
            guard needed, let shader else { continue }
            let pipe = compileComputeVariant(shader, key)
            cond.lock()
            if let pipe {
                pipelineCacheDirty = true
                if p.released || p.variants[key] != nil {
                    fn.vkDestroyPipeline!(ctx.pointee.device, pipe, nil)
                } else {
                    p.variants[key] = pipe
                }
            } else {
                p.failed.insert(key)
            }
            cond.unlock()
        }
    }

    // MARK: - Release

    func releaseRenderPipeline(_ p: VKRenderPipeline) {
        p.released = true
        for a in p.vertexStatics.memory + p.fragmentStatics.memory { releaseAllocationReference(a) }
        p.vertexStatics = StageStatics()
        p.fragmentStatics = StageStatics()
        let list = Array(p.variants.values)
        p.variants.removeAll()
        deferDestroy { [ctx, fn] in for v in list { fn.vkDestroyPipeline!(ctx.pointee.device, v, nil) } }
    }

    func releaseComputePipeline(_ p: VKComputePipeline) {
        p.released = true
        for a in p.statics.memory { releaseAllocationReference(a) }
        p.statics = StageStatics()
        let list = Array(p.variants.values)
        p.variants.removeAll()
        deferDestroy { [ctx, fn] in for v in list { fn.vkDestroyPipeline!(ctx.pointee.device, v, nil) } }
    }

    // MARK: - The persistent pipeline cache

    func loadPipelineCache() {
        var data: Data?
        if let path = options.pipelineCachePath { data = FileManager.default.contents(atPath: path) }
        let r: Int32 = data.map { d in d.withUnsafeBytes { yvk_pipeline_cache_create(ctx, $0.baseAddress, d.count) } }
            ?? yvk_pipeline_cache_create(ctx, nil, 0)
        if r != 0 { log("pipeline cache: creation failed") }
        if let path = options.pipelineCachePath {
            log("pipeline cache \(path): \(data?.count ?? 0) bytes loaded")
            let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
            let interval = max(options.pipelineCacheSaveInterval, 1)
            timer.schedule(deadline: .now() + interval, repeating: interval)
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                self.cond.lock()
                let dirty = self.pipelineCacheDirty
                self.pipelineCacheDirty = false
                self.cond.unlock()
                if dirty { self.savePipelineCache() }
            }
            cacheTimer = timer
            timer.resume()
        }
    }

    /// Writes the pipeline cache to `Options.pipelineCachePath` (atomically).
    public func savePipelineCache() {
        guard isAvailable, let path = options.pipelineCachePath else { return }
        var size = 0
        guard yvk_pipeline_cache_data(ctx, nil, &size) == VK_SUCCESS, size > 0 else { return }
        var bytes = [UInt8](repeating: 0, count: size)
        guard yvk_pipeline_cache_data(ctx, &bytes, &size) == VK_SUCCESS else { return }
        let url = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let tmp = path + ".tmp-\(getpid())"
        guard FileManager.default.createFile(atPath: tmp, contents: Data(bytes[0..<size])) else {
            log("pipeline cache: cannot write \(tmp)")
            return
        }
        if rename(tmp, path) != 0 { log("pipeline cache: cannot rename \(tmp)") }
    }
}

/// Carries a synchronous build's error out of its closure.
final class FailureBox: @unchecked Sendable {
    var error: Error?
}
