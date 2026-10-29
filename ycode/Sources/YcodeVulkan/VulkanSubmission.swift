// Submission, completion and CPU texture access of VulkanMetalBackend:
// command-buffer recycling, transient memory, the setup command buffer,
// the completion thread, replaceRegion and getBytes.

import CVulkan
import Foundation
import YcodeMetalHost

func roundUp(_ v: Int, _ a: Int) -> Int { a <= 1 ? v : (v + a - 1) / a * a }

private func gcd(_ a: Int, _ b: Int) -> Int { b == 0 ? a : gcd(b, a % b) }
func lcm(_ a: Int, _ b: Int) -> Int { a / gcd(a, b) * b }

/// Pipeline stages and access masks used for the coarse barriers.
let allCommands = VK_PIPELINE_STAGE_2_ALL_COMMANDS_BIT
let memoryWrite = VK_ACCESS_2_MEMORY_WRITE_BIT
let memoryReadWrite = VK_ACCESS_2_MEMORY_READ_BIT | VK_ACCESS_2_MEMORY_WRITE_BIT

extension VulkanMetalBackend {
    // MARK: - Recordings

    /// A command buffer in the recording state (recycled when possible). Under the lock.
    func newRecording() throws -> Recording {
        let rec: Recording
        if let cb = freeCommandBuffers.popLast(), yvk_command_buffer_restart(ctx, cb) == 0 {
            rec = Recording(cb: cb)
        } else {
            var err = [CChar](repeating: 0, count: 256)
            guard let cb = yvk_command_buffer_begin(ctx, &err, err.count) else {
                throw VulkanBackendError(cString(err))
            }
            rec = Recording(cb: cb)
        }
        rec.checkpointID = nextCheckpointID
        nextCheckpointID &+= 1
        return rec
    }

    /// The setup command buffer (image initialisation, uploads), submitted
    /// before the next command buffer or synchronous operation. Under the lock.
    func setupRecording() throws -> Recording {
        if let s = setup { return s }
        let s = try newRecording()
        setup = s
        return s
    }

    /// Submits pending setup work. Under the lock.
    func flushSetup() throws {
        guard let s = setup else { return }
        setup = nil
        if s.empty {
            _ = fn.vkEndCommandBuffer!(s.cb)
            freeCommandBuffers.append(s.cb!)
            for c in s.chunks { recycle(c) }
            return
        }
        _ = try submitRecording(s, entry: nil)
    }

    /// Ends and submits a recording; queues its completion entry. Under the lock.
    @discardableResult
    func submitRecording(_ rec: Recording, entry: PendingSubmission?) throws -> UInt64 {
        let r = fn.vkEndCommandBuffer!(rec.cb)
        guard r == VK_SUCCESS else {
            throw VulkanBackendError("vkEndCommandBuffer failed (\(r.rawValue))")
        }
        return try submitPreparedRecording(rec, entry: entry)
    }

    /// Submits an ended recording; queues its completion entry. Under the lock.
    @discardableResult
    func submitPreparedRecording(_ rec: Recording, entry: PendingSubmission?) throws -> UInt64 {
        let serial = lastSubmitted + 1
        let sr = yvk_submit(ctx, rec.cb, timeline, serial, rec.waitSemaphore, rec.waitValue)
        guard sr == VK_SUCCESS else {
            if sr == VK_ERROR_DEVICE_LOST {
                deviceLost = true
                reportDeviceLoss("vkQueueSubmit2 of " + (entry?.label ?? "a recording"))
            }
            throw VulkanBackendError("vkQueueSubmit2 failed (\(sr.rawValue))")
        }
        lastSubmitted = serial
        statistics.submissions += 1
        retireVisibilityPools(rec, serial: serial)
        for id in rec.writtenSurfaces { surfaceWriteSerials[id] = serial }
        // Held work's copy-outs were recorded (and their generation raised)
        // before images recorded since then copied the surface in; those
        // copies ran before this write, so they no longer match the surface.
        if rec.deferred { for k in rec.writtenSurfaceKeys { surfaceGenerations[k, default: 0] &+= 1 } }
        var e = entry ?? PendingSubmission(serial: serial, cb: nil, chunks: [], status: MetalCommandBufferStatus.completed)
        if options.earlyScheduled, let scheduled = e.scheduled {
            // On the queue, after every earlier submission: Metal's
            // "scheduled". Called once the lock is released (flushEarlyScheduled).
            earlyScheduledQueue.append(scheduled)
            e.scheduled = nil
            statistics.earlyScheduled += 1
        }
        if !options.recordFast && (rec.draws > 0 || rec.indirectDraws > 0) {
            e.label += (e.label.isEmpty ? "" : "; ") + "\(rec.draws) draws (largest \(rec.largestDraw)), \(rec.indirectDraws) indirect"
        }
        if !rec.shaders.isEmpty { e.label += (e.label.isEmpty ? "" : "; ") + "shaders " + rec.shaders.joined(separator: ", ") }
        if !rec.dispatchNotes.isEmpty { e.label += "; " + rec.dispatchNotes.joined(separator: "; ") }
        e.serial = serial
        e.cb = rec.cb
        e.chunks = rec.chunks
        pending.append(e)
        cond.broadcast()
        return serial
    }

    /// Calls the `scheduled` handlers queued at submission, in order. Not
    /// under the lock; the submitting thread and the completion thread both
    /// call it (the completion thread before any completion handler).
    func flushEarlyScheduled() {
        cond.lock()
        // A list another thread took and is still running counts too: the
        // completion thread must not run a completion handler before the
        // scheduled handler of the same command buffer has run.
        let any = !earlyScheduledQueue.isEmpty || scheduledFlushRunning
        cond.unlock()
        guard any else { return }
        // One flusher at a time keeps the order; taken before the backend
        // lock (a handler may take that lock).
        flushingScheduled.lock()
        cond.lock()
        let list = earlyScheduledQueue
        earlyScheduledQueue.removeAll()
        scheduledFlushRunning = !list.isEmpty
        cond.unlock()
        for f in list { f() }
        if !list.isEmpty {
            cond.lock(); scheduledFlushRunning = false; cond.unlock()
        }
        flushingScheduled.unlock()
    }

    /// Queues a completion that needs no GPU work of its own (it completes
    /// after everything submitted so far). Under the lock.
    func enqueueCompletion(status: Int, scheduled: (@Sendable () -> Void)?, completed: (@Sendable (Int) -> Void)?,
                           after: ((Bool) -> Void)? = nil) {
        pending.append(PendingSubmission(serial: lastSubmitted, cb: nil, chunks: [], status: status, scheduled: scheduled,
                                         completed: completed, after: after))
        cond.broadcast()
    }

    func recycle(_ c: TransientChunk) {
        c.used = 0
        if c.capacity == options.transientChunkSize && freeChunks.count < 16 {
            freeChunks.append(c)
        } else {
            yvk_buffer_destroy(ctx, &c.buffer)
        }
    }

    /// Host-visible memory with a device address for the recording's lifetime.
    func allocTransient(_ rec: Recording, _ size: Int, align: Int = 64) throws -> TransientSlice {
        if let c = rec.current {
            let off = roundUp(c.used, align)
            if off + size <= c.capacity {
                c.used = off + size
                return TransientSlice(chunk: c, offset: off, length: size)
            }
        }
        let chunk: TransientChunk
        if size <= options.transientChunkSize, let c = freeChunks.popLast() {
            chunk = c
        } else {
            let cap = max(options.transientChunkSize, roundUp(size, 1 << 16))
            var b = yvk_buffer()
            var err = [CChar](repeating: 0, count: 256)
            guard yvk_buffer_create(ctx, VkDeviceSize(cap), YVK_MEMORY_HOST, nil, &b, &err, err.count) == 0, b.mapped != nil else {
                throw VulkanBackendError("transient memory: \(cString(err))")
            }
            chunk = TransientChunk(buffer: b)
        }
        rec.chunks.append(chunk)
        rec.current = chunk
        chunk.used = size
        return TransientSlice(chunk: chunk, offset: 0, length: size)
    }

    /// A translated function's name and hash prefix (diagnostics).
    func shaderName(_ t: TranslatedShader?) -> String {
        guard let t else { return "-" }
        return "\(t.reflection.entryPoint ?? "?")#\(t.reflection.hash.map { String($0.prefix(8)) } ?? "?")"
    }

    func barrier(_ cb: VkCommandBuffer?) {
        yvk_cmd_memory_barrier(cb, allCommands, memoryWrite, allCommands, memoryReadWrite)
    }

    // MARK: - Completion thread

    func completionLoop() {
        while true {
            cond.lock()
            // At shutdown the held-work thread queues error completions for
            // what it still holds, so this thread ends after it.
            while pending.isEmpty && earlyScheduledQueue.isEmpty && (running || heldThread != nil) { cond.wait() }
            if !earlyScheduledQueue.isEmpty {
                cond.unlock()
                flushEarlyScheduled()
                continue
            }
            if pending.isEmpty && !running && heldThread == nil {
                completionThread = nil
                cond.unlock()
                return
            }
            let serial = pending[0].serial
            let sem = timeline
            let lost = deviceLost
            cond.unlock()

            var ok = !lost
            if serial > 0 && !lost {
                var waited = 0
                var slices = 0
                var reported = false
                let waitStart = DispatchTime.now().uptimeNanoseconds
                let slice = options.completionPollNs
                while true {
                    // Waits in short slices and reads the counter after each:
                    // on the Thor a blocking wait sometimes returned hundreds
                    // of milliseconds after the GPU had signaled the value
                    // (stage8-contract.md §14), which delays the guest's
                    // completion handlers and so its next frame.
                    var r = yvk_timeline_wait(ctx, sem, serial, slice)
                    if r == VK_TIMEOUT && yvk_timeline_value(ctx, sem) >= serial {
                        r = VK_SUCCESS
                        cond.lock(); statistics.lateWakeups += 1; cond.unlock()
                    }
                    if r == VK_SUCCESS { break }
                    if r == VK_TIMEOUT {
                        if !reported, options.hangReportSeconds > 0 {
                            let ran = Double(DispatchTime.now().uptimeNanoseconds &- waitStart) / 1e9
                            if ran >= options.hangReportSeconds {
                                reported = true
                                cond.lock(); reportRunningSubmission(serial: serial, seconds: ran); cond.unlock()
                            }
                        }
                        slices += 1
                        if UInt64(slices) * slice < 1_000_000_000 { continue }
                        slices = 0
                        waited += 1
                        cond.lock()
                        let label = pending.first?.label ?? ""
                        // Shutting down (stage8-contract.md §12): stop waiting
                        // at the deadline; the unfinished work is abandoned.
                        let giveUp = !running && DispatchTime.now().uptimeNanoseconds >= shutdownDeadline
                        if giveUp { abandonedAtShutdown = true }
                        cond.unlock()
                        if giveUp {
                            log("shutdown: serial \(serial) still running after \(waited) s; abandoned"
                                + (label.isEmpty ? "" : " (\(label))"))
                            ok = false
                            break
                        }
                        if waited % 10 == 0 {
                            cond.lock(); let where_ = currentCheckpoints(); cond.unlock()
                            log("serial \(serial) still running after \(waited) s\(label.isEmpty ? "" : " (\(label))")" + where_)
                        }
                        // A killed context does not always make the wait fail; the counter query says so.
                        var value: UInt64 = 0
                        if yvk_timeline_query(ctx, sem, &value) == VK_ERROR_DEVICE_LOST {
                            r = VK_ERROR_DEVICE_LOST
                        } else {
                            continue
                        }
                    }
                    log("waiting for serial \(serial) failed (\(r.rawValue)): device lost")
                    if r == VK_ERROR_DEVICE_LOST { cond.lock(); reportDeviceLoss("waiting for serial \(serial)"); cond.unlock() }
                    ok = false
                    break
                }
            }

            cond.lock()
            if !ok { deviceLost = true }
            // Abandoned at shutdown, the GPU may still use this work's
            // memory and objects: complete it as failed, but free nothing.
            let abandoning = abandonedAtShutdown
            var ready: [PendingSubmission] = []
            while let first = pending.first, first.serial <= serial || !ok {
                ready.append(pending.removeFirst())
            }
            if !abandoning { completedSerial = max(completedSerial, serial) }
            let now = DispatchTime.now().uptimeNanoseconds
            var traced: [(FrameTraceInfo, (UInt64, UInt64)?, [UInt64]?)] = []
            if let ft = frameTrace {
                for e in ready {
                    guard let t = e.trace else { continue }
                    if ok {
                        let segs = ft.segmentResults(device, fn, slot: t.slot, count: t.segments.count)
                        traced.append((t, ft.results(device, fn, slot: t.slot), segs))
                    } else {
                        ft.release(t.slot)
                        traced.append((t, nil, nil))
                    }
                }
            }
            for e in ready {
                if e.completed != nil {
                    let l = now &- e.queuedAt
                    statistics.completedCommandBuffers += 1
                    statistics.latencyTotalNs &+= l
                    statistics.latencyMaxNs = max(statistics.latencyMaxNs, l)
                    let bucket = VulkanBackendStatistics.latencyBucketLimitsNs.firstIndex { l < $0 }
                        ?? VulkanBackendStatistics.latencyBucketLimitsNs.count
                    statistics.latencyBuckets[bucket] += 1
                }
                e.after?(ok)
                if abandoning { continue }
                if let cb = e.cb { freeCommandBuffers.append(cb) }
                for c in e.chunks { recycle(c) }
            }
            if !abandoning {
                var keep: [(serial: UInt64, action: () -> Void)] = []
                let due = graveyard.filter { $0.serial <= completedSerial }
                for g in graveyard where g.serial > completedSerial { keep.append(g) }
                graveyard = keep
                for g in due { g.action() }
            }
            cond.unlock()

            flushEarlyScheduled()
            for e in ready {
                e.scheduled?()
                e.completed?(ok ? e.status : MetalCommandBufferStatus.error)
            }
            if !traced.isEmpty, let ft = frameTrace {
                let handlers = DispatchTime.now().uptimeNanoseconds
                ft.write(traced.map { ft.line($0.0, gpu: $0.1, segments: $0.2, done: now, handlers: handlers) })
            }
        }
    }

    /// Waits (at most `timeout` seconds) until the GPU work submitted so far
    /// that writes the IOSurface `surfaceID` is complete; true when it is
    /// (or there is none). Any thread; never under the IOSurface service's lock.
    @discardableResult
    public func waitForSurfaceWrites(_ surfaceID: UInt32, timeout: Double = 0.5) -> Bool {
        guard isAvailable else { return true }
        cond.lock()
        let serial = surfaceWriteSerials[surfaceID] ?? 0
        let sem = timeline
        let lost = deviceLost
        let stuckAt = surfaceWaitStuckAt
        cond.unlock()
        guard serial > 0, !lost, let sem else { return true }
        let now = yvk_timeline_value(ctx, sem)
        guard now < serial else { return true }
        // A GPU that made no progress since an earlier wait timed out (a
        // submission that never completes, app-launch.md §3.7) gets only a
        // short look (5 ms): every lock and display read would otherwise
        // cost the whole timeout. Full waits resume once the counter moves.
        let limit = stuckAt == now ? min(timeout, 0.005) : timeout
        let start = DispatchTime.now().uptimeNanoseconds
        let limitNs = UInt64(max(limit, 0) * 1e9)
        var r: VkResult
        if options.surfaceWaitPollNs == 0 {
            r = yvk_timeline_wait(ctx, sem, serial, limitNs)
        } else {
            // In slices, reading the counter after each (a blocking wait often
            // wakes late on the Thor).
            while true {
                let waited = DispatchTime.now().uptimeNanoseconds &- start
                r = yvk_timeline_wait(ctx, sem, serial, min(options.surfaceWaitPollNs, limitNs &- min(waited, limitNs)))
                if r == VK_TIMEOUT && yvk_timeline_value(ctx, sem) >= serial { r = VK_SUCCESS }
                if r != VK_TIMEOUT || DispatchTime.now().uptimeNanoseconds &- start >= limitNs { break }
            }
        }
        cond.lock()
        statistics.surfaceWriteWaits.add(DispatchTime.now().uptimeNanoseconds &- start)
        if r == VK_TIMEOUT {
            let after = yvk_timeline_value(ctx, sem)
            if after < serial && surfaceWaitStuckAt != after {
                surfaceWaitStuckAt = after
                statistics.surfaceWriteWaitTimeouts += 1
            }
        } else {
            surfaceWaitStuckAt = nil
        }
        cond.unlock()
        return r == VK_SUCCESS
    }

    /// Blocks until all work submitted so far is complete.
    public func waitIdle() {
        guard isAvailable else { return }
        let done = DispatchSemaphore(value: 0)
        cond.lock()
        try? flushSetup()
        enqueueCompletion(status: 0, scheduled: nil, completed: nil, after: { _ in done.signal() })
        cond.unlock()
        done.wait()
    }

    // MARK: - CPU access to textures

    /// The copy aspect and bytes per texel/block of a texture for buffer copies.
    func copyAspect(_ tex: VKTexture, options: UInt32 = 0) -> (VkImageAspectFlags, Int) {
        let f = tex.format
        if f.isColor { return (VK_IMAGE_ASPECT_COLOR_BIT.rawValue, f.bytesPerBlock) }
        let wantStencil = (f.isStencil && !f.isDepth) || options & 2 != 0 ||
            (f.viewAspect == VK_IMAGE_ASPECT_STENCIL_BIT.rawValue && options & 1 == 0)
        if wantStencil { return (VK_IMAGE_ASPECT_STENCIL_BIT.rawValue, 1) }
        switch f.format {
        case VK_FORMAT_D16_UNORM, VK_FORMAT_D16_UNORM_S8_UINT: return (VK_IMAGE_ASPECT_DEPTH_BIT.rawValue, 2)
        default: return (VK_IMAGE_ASPECT_DEPTH_BIT.rawValue, 4)
        }
    }

    /// A buffer↔image copy region for a Metal region of one level and slice.
    func copyRegion(_ tex: VKTexture, level: Int, slice: Int, origin: (Int, Int, Int), size: (Int, Int, Int),
                    bufferOffset: Int, bytesPerRow: Int, bytesPerImage: Int, options: UInt32 = 0) -> VkBufferImageCopy {
        let (aspect, bpb) = copyAspect(tex, options: options)
        let f = tex.format
        let is3D = tex.image.imageType == VK_IMAGE_TYPE_3D
        let (lw, lh, ld) = tex.levelSize(level)
        let w = max(0, min(size.0, lw - origin.0)), h = max(0, min(size.1, lh - origin.1))
        let d = is3D ? max(0, min(size.2, ld - origin.2)) : 1
        let rowTexels = bytesPerRow > 0 && bpb > 0 ? bytesPerRow / bpb * f.blockWidth : 0
        let imageRows = bytesPerImage > 0 && bytesPerRow > 0 ? bytesPerImage / bytesPerRow * f.blockHeight : 0
        return VkBufferImageCopy(
            bufferOffset: VkDeviceSize(bufferOffset), bufferRowLength: UInt32(rowTexels), bufferImageHeight: UInt32(imageRows),
            imageSubresource: VkImageSubresourceLayers(aspectMask: aspect, mipLevel: UInt32(tex.baseLevel + level),
                                                       baseArrayLayer: UInt32(is3D ? 0 : tex.baseLayer + slice), layerCount: 1),
            imageOffset: VkOffset3D(x: Int32(origin.0), y: Int32(origin.1), z: Int32(is3D ? origin.2 : 0)),
            imageExtent: VkExtent3D(width: UInt32(w), height: UInt32(h), depth: UInt32(d)))
    }

    /// Bytes a Metal region occupies with the given row and image pitches.
    func regionBytes(_ tex: VKTexture, width: Int, height: Int, depth: Int, bytesPerRow: Int, bytesPerImage: Int) -> Int {
        let f = tex.format
        let (_, bpb) = copyAspect(tex)
        let rows = (height + f.blockHeight - 1) / f.blockHeight
        let rowBytes = (width + f.blockWidth - 1) / f.blockWidth * bpb
        let image = (rows - 1) * max(bytesPerRow, rowBytes) + rowBytes
        return depth <= 1 ? image : (depth - 1) * max(bytesPerImage, image) + image
    }

    /// Writes pixels into a texture. An IOSurface-backed texture (level 0,
    /// slice 0) is written directly in surface memory; any other texture
    /// gets a staged copy recorded into the setup command buffer. Throws
    /// without a GPU or for an unknown texture.
    public func replaceRegion(texture: MetalHandle, _ region: MetalRegion, level: Int, slice: Int, bytes: [UInt8],
                              bytesPerRow: Int, bytesPerImage: Int) throws {
        guard isAvailable else { throw VulkanBackendError("no GPU") }
        cond.lock(); defer { cond.unlock() }
        guard let tex = textures[texture] else { throw VulkanBackendError("replaceRegion of unknown texture \(texture)") }
        let need = regionBytes(tex, width: region.width, height: region.height, depth: region.depth,
                               bytesPerRow: bytesPerRow, bytesPerImage: bytesPerImage)
        guard bytes.count >= min(need, bytes.count), !bytes.isEmpty else { return }
        if let s = tex.image.surface, level == 0, slice == 0, let base = s.allocation.base {
            // IOSurface texture: the surface memory is the texture's content.
            surfaceChanged(s)
            let bpb = tex.format.bytesPerBlock
            let x0 = region.x * bpb
            let rowBytes = min(region.width * bpb, max(0, s.bytesPerRow - x0))
            for y in 0..<region.height where rowBytes > 0 && y * bytesPerRow + rowBytes <= bytes.count {
                let at = (region.y + y) * s.bytesPerRow + x0
                guard at + rowBytes <= s.limit else { break }
                bytes.withUnsafeBytes { src in (base + s.offset + at).copyMemory(from: src.baseAddress! + y * bytesPerRow, byteCount: rowBytes) }
            }
            return
        }
        let rec = try setupRecording()
        let (_, bpb) = copyAspect(tex)
        let staging = try allocTransient(rec, bytes.count, align: lcm(64, max(bpb, 4)))
        bytes.withUnsafeBytes { staging.pointer.copyMemory(from: $0.baseAddress!, byteCount: bytes.count) }
        var copy = copyRegion(tex, level: level, slice: slice, origin: (region.x, region.y, region.z),
                              size: (region.width, region.height, region.depth), bufferOffset: staging.offset,
                              bytesPerRow: bytesPerRow, bytesPerImage: bytesPerImage)
        barrier(rec.cb)
        fn.vkCmdCopyBufferToImage!(rec.cb, staging.vkBuffer, tex.image.vkImage, VK_IMAGE_LAYOUT_GENERAL, 1, &copy)
        barrier(rec.cb)
        rec.empty = false
    }

    /// Reads pixels into guest memory through a staging copy, and blocks
    /// until the GPU has run it (after all work submitted before). At most
    /// `into.length` bytes are written. Throws without a GPU or for an
    /// unknown texture.
    public func getBytes(texture: MetalHandle, _ region: MetalRegion, level: Int, slice: Int, into: GuestSharedRegion,
                         bytesPerRow: Int, bytesPerImage: Int) throws {
        guard isAvailable else { throw VulkanBackendError("no GPU") }
        let done = DispatchSemaphore(value: 0)
        var failure: Error?
        cond.lock()
        do {
            guard let tex = textures[texture] else { throw VulkanBackendError("getBytes of unknown texture \(texture)") }
            try flushSetup()
            let need = regionBytes(tex, width: region.width, height: region.height, depth: region.depth,
                                   bytesPerRow: bytesPerRow, bytesPerImage: bytesPerImage)
            let rec = try newRecording()
            let (_, bpb) = copyAspect(tex)
            let staging = try allocTransient(rec, need, align: lcm(64, max(bpb, 4)))
            var copy = copyRegion(tex, level: level, slice: slice, origin: (region.x, region.y, region.z),
                                  size: (region.width, region.height, region.depth), bufferOffset: staging.offset,
                                  bytesPerRow: bytesPerRow, bytesPerImage: bytesPerImage)
            barrier(rec.cb)
            fn.vkCmdCopyImageToBuffer!(rec.cb, tex.image.vkImage, VK_IMAGE_LAYOUT_GENERAL, staging.vkBuffer, 1, &copy)
            yvk_cmd_memory_barrier(rec.cb, allCommands, memoryWrite, VK_PIPELINE_STAGE_2_HOST_BIT, VK_ACCESS_2_HOST_READ_BIT)
            let n = min(need, into.length)
            let src = staging.pointer
            let dst = into.pointer
            let entry = PendingSubmission(serial: 0, cb: nil, chunks: [], status: 0, scheduled: nil, completed: nil,
                                          after: { ok in
                                              if ok { dst.copyMemory(from: src, byteCount: n) }
                                              done.signal()
                                          })
            try submitRecording(rec, entry: entry)
        } catch {
            failure = error
        }
        cond.unlock()
        if let failure { throw failure }
        done.wait()
    }
}

/// The text of a NUL-terminated C error buffer.
func cString(_ a: [CChar]) -> String {
    String(decoding: a.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
}
