// Device recovery of VulkanMetalBackend (metal-sim-protocol.md §8.7).
//
// A Vulkan device that is lost stays lost: every later submission and wait
// fails. On the Thor a GPU hang ends in a loss only when another context
// needs the GPU (stage8-contract.md §15.1), which can take minutes; the GPU
// watchdog (VulkanSubmission.swift) ends a submission that runs too long by
// waiting the device idle, which makes the driver stop the stuck work
// (Xid 109) and return VK_ERROR_DEVICE_LOST within about 1.3 s.
//
// Then the completion thread makes the device again and rebuilds every
// object in place, under the handles, heap slots and (with capture replay)
// device addresses the guest knows:
//
// - buffers: guest-memory imports are imported again (their contents are the
//   guest's pages); owned host memory is copied over; private (device)
//   memory comes back zeroed;
// - textures: the image is created again from its create info (contents are
//   lost; an IOSurface texture copies its surface in before the next use)
//   with its views, written into the same heap slots;
// - samplers into their slots, events at the highest value signaled or
//   scheduled for them (waits on work that failed do not hang), pipelines
//   with their translated shaders (variants compile again on first use);
// - the work that was running fails (`MTLCommandBufferStatusError`); every
//   other command buffer that was queued, held behind an event or refused
//   meanwhile is recorded again on the new device and runs, so its client
//   (the render server above all) never sees the loss.
//
// The device gate keeps every device use outside `cond` (pipeline compiles,
// timeline waits, pipeline-cache saves) out while the device is replaced.

import CVulkan
import Foundation
import YcodeMetalHost

extension VulkanMetalBackend {
    // MARK: The device gate

    /// Enters a device use outside `cond` (waits while a reset runs).
    func enterDevice() {
        gate.lock()
        while gateClosed { gate.wait() }
        gateUsers += 1
        gate.unlock()
    }

    func leaveDevice() {
        gate.lock()
        gateUsers -= 1
        if gateUsers == 0 { gate.broadcast() }
        gate.unlock()
    }

    public func setDeviceResetHandler(_ handler: @escaping @Sendable () -> Void) {
        cond.lock(); defer { cond.unlock() }
        deviceResetHandler = handler
    }

    /// Whether a lost device is made again (under the lock).
    var canRecover: Bool { options.recoverDevice && !recoveryGivenUp && running }

    /// Device resets so far (tests, diagnostics).
    public var deviceResetCount: Int {
        cond.lock(); defer { cond.unlock() }
        return deviceResets
    }

    /// The last reset's report (tests, diagnostics).
    public var lastDeviceResetReport: String {
        cond.lock(); defer { cond.unlock() }
        return lastResetReport
    }

    /// A command buffer to record again after the reset (or to fail).
    struct ResubmitItem {
        var commandBuffer: MetalCommandBuffer?
        /// The status a completion without GPU work of its own reports.
        var status = MetalCommandBufferStatus.completed
        var scheduled: (@Sendable () -> Void)?
        var completed: (@Sendable (Int) -> Void)?
        var after: ((Bool) -> Void)?
        var guilty: Bool
    }

    /// A command buffer refused because the device was lost (submission
    /// failed with VK_ERROR_DEVICE_LOST): kept for the reset to record again.
    /// Under the lock. False when the device will not be made again.
    func parkForReset(_ mcb: MetalCommandBuffer?, scheduled: (@Sendable () -> Void)?,
                      completed: (@Sendable (Int) -> Void)?) -> Bool {
        guard canRecover, let mcb else { return false }
        parked.append(ResubmitItem(commandBuffer: mcb, scheduled: scheduled, completed: completed, after: nil, guilty: false))
        cond.broadcast()
        return true
    }

    // MARK: The reset

    /// Makes the device again after a loss and rebuilds every object in
    /// place (see the file comment). `stuckSerial`: the submission that was
    /// running (its command buffer fails). On the completion thread, without
    /// the lock.
    func recoverDevice(stuckSerial: UInt64) {
        let started = DispatchTime.now().uptimeNanoseconds
        var phases: [String] = []
        var phaseStart = started
        func phase(_ name: String) {
            let now = DispatchTime.now().uptimeNanoseconds
            phases.append(String(format: "%@ %.0f", name, Double(now &- phaseStart) / 1e6))
            phaseStart = now
        }
        // No device use outside the lock from here on.
        gate.lock()
        gateClosed = true
        while gateUsers > 0 { gate.wait() }
        gate.unlock()
        // Pipeline builds that passed the gate before are done; queued ones
        // wait at the gate and build on the new device.
        phase("gate")

        cond.lock()
        let fired = watchdogFired
        watchdogFired = false
        deviceLost = true
        // The device is lost (or the watchdog made it so): this returns at once.
        _ = fn.vkDeviceWaitIdle!(ctx.pointee.device)
        phase("idle")

        // 1. The work: the stuck command buffer fails, the rest runs again.
        var items: [ResubmitItem] = []
        var guiltyFound = false
        var oldChunks: [TransientChunk] = []
        for e in pending.sorted(by: { $0.serial < $1.serial }) {
            oldChunks += e.chunks
            if let t = e.trace, let ft = frameTrace { ft.release(t.slot) }
            let guilty = !guiltyFound && e.commandBuffer != nil && e.serial >= stuckSerial
            if guilty { guiltyFound = true }
            items.append(ResubmitItem(commandBuffer: e.commandBuffer, status: e.status, scheduled: e.scheduled,
                                      completed: e.completed, after: e.after, guilty: guilty))
        }
        pending.removeAll()
        for key in held.keys.sorted(by: { ($0.process, $0.queue?.raw ?? 0) < ($1.process, $1.queue?.raw ?? 0) }) {
            for case let .submit(rec, entry) in held[key] ?? [] {
                oldChunks += rec.chunks
                guard let entry else { continue }
                items.append(ResubmitItem(commandBuffer: entry.commandBuffer, status: entry.status, scheduled: entry.scheduled,
                                          completed: entry.completed, after: entry.after, guilty: false))
            }
        }
        held.removeAll()
        heldSince.removeAll()
        heldReported.removeAll()
        items += parked
        parked.removeAll()
        if let s = setup { oldChunks += s.chunks }
        setup = nil
        // The stuck client's other command buffers fail with it
        // (VulkanClientIsolation.swift); it may lose GPU access.
        let blamed = blameStuckClient(&items)
        // Their after-completion steps (CPU reads of the lost work, probe
        // read-backs) end now, on the old device.
        for i in items.indices {
            items[i].after?(false)
            items[i].after = nil
        }

        // 2. Deferred destroys of released objects (legal on a lost device).
        // (An action may defer another one: until none is left.)
        while !graveyard.isEmpty || !heldGraveyard.isEmpty {
            let deferred = graveyard.map(\.action) + heldGraveyard
            graveyard.removeAll()
            heldGraveyard.removeAll()
            for a in deferred { a() }
        }

        phase("work")
        // 3. The old device's objects: contents to keep, then destroy.
        var allocations: [ObjectIdentifier: VKAllocation] = [:]
        func addAllocation(_ a: VKAllocation) { allocations[ObjectIdentifier(a)] = a }
        for b in buffers.values { addAllocation(b.allocation) }
        for a in imports.values { addAllocation(a) }
        var images: [ObjectIdentifier: VKImage] = [:]
        for t in textures.values {
            images[ObjectIdentifier(t.image)] = t.image
            if let s = t.image.surface { addAllocation(s.allocation) }
        }
        // Owned host memory keeps its bytes; captured device addresses.
        var saved: [ObjectIdentifier: Data] = [:]
        var capture: [ObjectIdentifier: (address: UInt64, captureAddress: UInt64, size: VkDeviceSize)] = [:]
        for (id, a) in allocations {
            capture[id] = (a.buffer.address, a.buffer.captureAddress, a.buffer.size)
            if a.key == nil, let p = a.buffer.mapped, a.buffer.size > 0 { saved[id] = Data(bytes: p, count: Int(a.buffer.size)) }
        }
        let device = ctx.pointee.device
        for a in allocations.values { yvk_buffer_destroy(ctx, &a.buffer) }
        for t in textures.values { destroyViews(t) }
        for i in images.values { yvk_image_destroy(ctx, &i.image) }
        for t in feedbackCopies.values {
            destroyViews(t)
            yvk_image_destroy(ctx, &t.image.image)
            if t.heapIndex != 0 { textureIndices.release(t.heapIndex, count: max(t.heapCount, 1)) }
        }
        feedbackCopies.removeAll()
        textureOverride.removeAll()
        var samplerObjects: [ObjectIdentifier: VKSampler] = [:]
        for s in samplerCache.values { samplerObjects[ObjectIdentifier(s)] = s }
        for s in samplers.values { samplerObjects[ObjectIdentifier(s)] = s }
        for s in samplerObjects.values {
            if let v = s.sampler { fn.vkDestroySampler!(device, v, nil) }
            s.sampler = nil
        }
        var eventObjects: [ObjectIdentifier: VKEvent] = [:]
        for e in events.values { eventObjects[ObjectIdentifier(e)] = e }
        for e in eventObjects.values {
            if let s = e.semaphore { fn.vkDestroySemaphore!(device, s, nil) }
            e.semaphore = nil
        }
        for p in renderPipelines.values {
            for v in p.variants.values { fn.vkDestroyPipeline!(device, v, nil) }
            p.variants.removeAll()
            p.failed.removeAll()
            for a in p.vertexStatics.memory + p.fragmentStatics.memory { yvk_buffer_destroy(ctx, &a.buffer) }
            p.vertexStatics = StageStatics()
            p.fragmentStatics = StageStatics()
        }
        for p in computePipelines.values {
            for v in p.variants.values { fn.vkDestroyPipeline!(device, v, nil) }
            p.variants.removeAll()
            p.failed.removeAll()
            for a in p.statics.memory { yvk_buffer_destroy(ctx, &a.buffer) }
            p.statics = StageStatics()
        }
        for p in libraries.removeAll() { fn.vkDestroyPipeline!(device, p, nil) }
        for c in oldChunks + freeChunks { yvk_buffer_destroy(ctx, &c.buffer) }
        freeChunks.removeAll()
        freeCommandBuffers.removeAll()  // freed with the command pool
        for p in freeVisibilityPools { fn.vkDestroyQueryPool!(device, p, nil) }
        freeVisibilityPools.removeAll()
        if let ft = frameTrace {
            ft.destroy(device, fn)
            frameTrace = nil
            log("frame trace: stopped by the device reset")
        }
        if let p = probe { yvk_buffer_destroy(ctx, &p.buffer); probe = nil }
        depthTapDeviceLost(device)
        if let s = defaultSampler { fn.vkDestroySampler!(device, s, nil) }
        defaultSampler = nil
        if let v = dummyView { fn.vkDestroyImageView!(device, v, nil) }
        dummyView = nil
        if let d = dummyImage { yvk_image_destroy(ctx, &d.image) }
        dummyImage = nil
        yvk_buffer_destroy(ctx, &dummyBuffer)
        if let t = timeline { fn.vkDestroySemaphore!(device, t, nil) }
        timeline = nil

        phase("objects")
        // 4. The new device.
        yvk_context_destroy(ctx)
        phase("destroy")
        var opts = yvk_context_options(maxSampledImages: options.maxSampledImages, maxSamplers: options.maxSamplers,
                                       maxStorageImages: options.maxStorageImages, validation: options.validation ? 1 : 0,
                                       queues: 1, second: 0)
        var err = [CChar](repeating: 0, count: 512)
        let created = yvk_context_create(ctx, &opts, &err, err.count) == 0
        fn = yvk_fns().pointee
        timeline = created ? yvk_timeline_create(ctx, 0) : nil
        guard created, timeline != nil else {
            // No device: every command buffer fails from now on.
            let why = created ? "timeline semaphore creation failed" : cString(err)
            lastResetReport = "the device could not be made again: \(why)"
            log("device reset: " + lastResetReport)
            recoveryGivenUp = true
            cond.unlock()
            reopenGate()
            finish(items, resubmit: false)
            return
        }
        lastSubmitted = 0
        completedSerial = 0
        phase("create")

        // 5. Rebuild, buffers first: capture-replay addresses are requested
        // before anything else takes device address space.
        var failures: [String] = []
        var moved = 0
        for (id, a) in allocations {
            guard let old = capture[id] else { continue }
            var b = yvk_buffer()
            // An import is of the same guest pages (the import key's range).
            let host: UnsafeMutableRawPointer? = a.key.flatMap { UnsafeMutableRawPointer(bitPattern: $0.start) }
            let size = a.key.map { VkDeviceSize($0.length) } ?? max(old.size, 4)
            if yvk_buffer_recreate(ctx, size, a.kind, host, old.captureAddress, &b, &err, err.count) == 0 {
                a.buffer = b
                if a.key == nil { a.base = b.mapped }
                if b.address != old.address { moved += 1 }
                if let d = saved[id], let p = b.mapped {
                    d.withUnsafeBytes { p.copyMemory(from: $0.baseAddress!, byteCount: min(d.count, Int(b.size))) }
                }
            } else if failures.count < 8 {
                failures.append("buffer: \(cString(err))")
            }
        }
        do {
            try createDummiesLocked()
        } catch {
            failures.append("dummy resources: \(error)")
        }
        createPipelineCache()
        for image in images.values {
            var info = image.createInfo
            var img = yvk_image()
            if yvk_image_create(ctx, &info, &img, &err, err.count) == 0 {
                image.image = img
                image.syncedGeneration = nil
                do { try initializeImage(image) } catch { failures.append("image layout: \(error)") }
            } else if failures.count < 8 {
                failures.append("image \(image.width)x\(image.height): \(cString(err))")
            }
        }
        for (h, t) in textures where t.textureType != MetalTextureType.typeTextureBuffer {
            makeShaderViews(t, handle: h, keepSlot: true)
        }
        for s in samplerObjects.values {
            var info = samplerInfo(s.key)
            s.sampler = yvk_sampler_create(ctx, &info, &err, err.count)
            if let v = s.sampler { yvk_heap_write_sampler(ctx, s.heapIndex, v) } else if failures.count < 8 {
                failures.append("sampler: \(cString(err))")
            }
        }
        for e in eventObjects.values { e.semaphore = yvk_timeline_create(ctx, e.highest) }
        for p in renderPipelines.values {
            do {
                if let v = p.vertex { p.vertexStatics = try statics(for: v.reflection) }
                if let f = p.fragment { p.fragmentStatics = try statics(for: f.reflection) }
            } catch {
                failures.append("render pipeline constants: \(error)")
            }
        }
        for p in computePipelines.values {
            guard let s = p.shader else { continue }
            do { p.statics = try statics(for: s.reflection) } catch { failures.append("compute pipeline constants: \(error)") }
        }
        try? flushSetup()
        phase("rebuild")

        // 6. Done.
        checkpointRecords.removeAll()
        surfaceWriteSerials.removeAll()
        surfaceWaitStuckAt = nil
        releasedBufferRanges.removeAll()
        deviceLost = false
        deviceLossReported = false
        deviceResets += 1
        let ms = Double(DispatchTime.now().uptimeNanoseconds &- started) / 1e6
        let resubmitted = items.filter { !$0.guilty && $0.commandBuffer != nil }.count
        lastResetReport = String(format: "device made again in %.0f ms (reset %d, %@): ", ms, deviceResets,
                                 fired ? "after the watchdog" : "after a device loss")
            + "\(allocations.count) buffers and imports (\(moved) at a new device address), \(images.count) images, "
            + "\(textures.count) textures, \(samplerObjects.count) samplers, \(eventObjects.count) events, "
            + "\(renderPipelines.count) render and \(computePipelines.count) compute pipelines; "
            + "\(items.filter(\.guilty).count) command buffer(s) failed"
            + (blamed.map { " (\(knownClient($0.process))'s)" } ?? "") + ", \(resubmitted) recorded again"
            + (failures.isEmpty ? "" : "; failures: " + failures.joined(separator: "; "))
            + " (ms: " + phases.joined(separator: ", ") + ")"
        log(lastResetReport)
        cond.broadcast()
        cond.unlock()
        reopenGate()
        cond.lock()
        let handler = deviceResetHandler
        cond.unlock()
        handler?()
        if let b = blamed { revokeIfDue(b.process, hangs: b.hangs) }
        finish(items, resubmit: true)
    }

    private func reopenGate() {
        gate.lock()
        gateClosed = false
        gate.broadcast()
        gate.unlock()
    }

    /// Fails the stuck command buffer and records the others again (in
    /// their order). Not under the lock.
    private func finish(_ items: [ResubmitItem], resubmit: Bool) {
        for item in items {
            guard resubmit, !item.guilty, let mcb = item.commandBuffer else {
                // A completion with no GPU work of its own keeps its status.
                let ok = resubmit && !item.guilty && item.commandBuffer == nil
                item.scheduled?()
                item.completed?(ok ? item.status : MetalCommandBufferStatus.error)
                continue
            }
            submit(mcb, scheduled: item.scheduled ?? {}, completed: item.completed ?? { _ in })
        }
    }

    /// Destroys a texture's views (the image is destroyed by the caller). Under the lock.
    private func destroyViews(_ t: VKTexture) {
        let device = ctx.pointee.device
        for v in [t.shaderView, t.storageView].compactMap({ $0 }) + t.levelStorageViews + t.attachmentViews.values.compactMap({ $0 }) {
            fn.vkDestroyImageView!(device, v, nil)
        }
        t.shaderView = nil
        t.storageView = nil
        t.levelStorageViews.removeAll()
        t.attachmentViews.removeAll()
    }
}
