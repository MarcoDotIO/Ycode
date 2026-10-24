// VulkanMetalBackend: the Metal host service's GPU back end on Vulkan
// (stage8-contract.md §5.2–§5.3, owner VK). Written from
// specs/simulator/metal-sim-protocol.md, specs/simulator/metal-shaders.md
// §4–§5, the Vulkan specification and public Metal documentation.
//
// Model:
// - One Vulkan device and queue; one timeline semaphore numbers every
//   queue submission ("serial"). A completion thread waits for serials in
//   order, recycles their memory, destroys released objects whose last use
//   is done, and calls the Metal completion handlers.
// - Every image lives in VK_IMAGE_LAYOUT_GENERAL. Passes are separated by
//   full memory barriers (Metal tracks hazards for the guest; we do not
//   analyse them), command buffers start with one and end with a barrier to
//   host reads.
// - Shared buffers are the guest's pages, imported with
//   VK_EXT_external_memory_host (4096-aligned containing range, cached per
//   backing object). Private buffers are device memory.
// - Textures are host-owned images. IOSurface textures also link to the
//   surface's memory: a command buffer that reads one copies the surface in
//   first, one that writes it copies it back before completion, so the
//   pixels are in surface memory before `scheduled` is called.
// - Shaders: translated by a ShaderTranslator (ycode-airc), bound per the
//   Ycode Metal ABI (ShaderTranslation.swift).

import CVulkan
import Foundation
import YcodeMetalHost

public struct VulkanBackendError: Error, CustomStringConvertible, Sendable {
    public var description: String
    public init(_ d: String) { description = d }
}

public final class VulkanMetalBackend: MetalBackend, @unchecked Sendable {
    public struct Options: Sendable {
        public var maxSampledImages: UInt32 = 0
        public var maxSamplers: UInt32 = 0
        public var maxStorageImages: UInt32 = 0
        public var validation = false
        /// Size of each transient chunk (argument tables, staging).
        public var transientChunkSize = 4 << 20
        public var log: (@Sendable (String) -> Void)?
        /// Translate and compile pipelines on worker threads; creation calls
        /// return at once and submissions wait for the pipelines they use.
        public var asynchronousPipelines = true
        /// Worker threads for translation and pipeline compiles.
        public var compileThreads = 4
        /// `ycode-airc serve` processes (when no translator is given).
        public var translatorProcesses = ProcessInfo.processInfo.environment["YCODE_AIRC_PROCESSES"].flatMap { Int($0) }.map { max($0, 1) } ?? 4
        /// Where the VkPipelineCache is loaded from and saved to (default:
        /// $YCODE_VULKAN_PIPELINE_CACHE; nil: not persistent).
        public var pipelineCachePath: String? = ProcessInfo.processInfo.environment["YCODE_VULKAN_PIPELINE_CACHE"]
        /// Copy back to an IOSurface only the part of it a command buffer's
        /// render passes can have drawn (the union of their scissor rects);
        /// `YCODE_GPU_SURFACE_DAMAGE=0`: the whole surface every time.
        public var surfaceDamage = ProcessInfo.processInfo.environment["YCODE_GPU_SURFACE_DAMAGE"] != "0"
        /// Skip copying an IOSurface in when the image already holds its
        /// pixels; `YCODE_GPU_SURFACE_SKIP_IN=0`: copy it in every time.
        public var surfaceSkipCopyIn = ProcessInfo.processInfo.environment["YCODE_GPU_SURFACE_SKIP_IN"] != "0"
        /// The completion thread waits for the GPU in slices of this many
        /// ns and reads the timeline counter after each
        /// (`YCODE_GPU_COMPLETION_POLL_US`, default 1000; 1000000: one
        /// blocking wait per second as before).
        public var completionPollNs: UInt64 = UInt64(ProcessInfo.processInfo.environment["YCODE_GPU_COMPLETION_POLL_US"]
            .flatMap { UInt64($0) }.map { max($0, 50) } ?? 1000) * 1000
        /// Report `scheduled` as soon as a command buffer is on the Vulkan
        /// queue (Metal's meaning) instead of at completion; CPU access to
        /// an IOSurface the GPU is still writing then waits for the write
        /// (`waitForSurfaceWrites`, called by the IOSurface service on locks
        /// and host reads). `YCODE_GPU_EARLY_SCHEDULED=0`: at completion.
        public var earlyScheduled = ProcessInfo.processInfo.environment["YCODE_GPU_EARLY_SCHEDULED"] != "0"
        /// A CPU access that waits for pending GPU writes to an IOSurface
        /// (`waitForSurfaceWrites`) waits in slices of this many ns and reads
        /// the timeline counter after each: a blocking wait on the Thor
        /// often returns late (§14.2 item 3). `YCODE_GPU_SURFACE_WAIT_POLL_US`
        /// (default 200; 0: one blocking wait as before).
        public var surfaceWaitPollNs: UInt64 = UInt64(ProcessInfo.processInfo.environment["YCODE_GPU_SURFACE_WAIT_POLL_US"]
            .flatMap { UInt64($0) } ?? 200) * 1000
        /// Kernels (by entry-point name) dispatched one thread per
        /// workgroup when their reflection allows it (§15.5): the guest
        /// driver's ASTC decoder hangs the Thor's GPU when two lanes of one
        /// subgroup decode different kinds of blocks. `YCODE_GPU_LANE_ISOLATED`
        /// (comma-separated names; default `astc`; empty: none).
        public var laneIsolatedKernels: Set<String> = Set((ProcessInfo.processInfo.environment["YCODE_GPU_LANE_ISOLATED"] ?? "astc")
            .split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
        /// Experimental, off by default (§15.6): import guest memory with this
        /// many bytes of the host memory around the backing object, so that
        /// a read a little outside it lands in mapped memory (on the Thor a
        /// GPU access to an unmapped GPU address stalls the GPU for good).
        /// On the Thor's driver imports that overlap other imports (or the
        /// driver's own mappings) made later allocations fail with
        /// VK_ERROR_OUT_OF_DEVICE_MEMORY, so it is not usable there.
        /// `YCODE_GPU_IMPORT_SLACK_KB` (default 0). Only inside `importSlackWindow`.
        public var importSlack = (Int(ProcessInfo.processInfo.environment["YCODE_GPU_IMPORT_SLACK_KB"] ?? "") ?? 0) * 1024
        /// The host memory slack may come from (start, length): the shared
        /// object arena, which holds only guest objects. Nil: no slack (the
        /// memory around other mappings may be anything, the driver's own
        /// mappings included: importing those broke later allocations).
        public var importSlackWindow: (UInt, UInt)?
        /// A draw that samples a color attachment of its own pass samples a
        /// copy made just before it (§15.6). `YCODE_GPU_FEEDBACK_COPY=0`: it
        /// samples the attachment itself, as before.
        public var feedbackSnapshots = ProcessInfo.processInfo.environment["YCODE_GPU_FEEDBACK_COPY"] != "0"
        /// Feedback copies copy only the draw's scissor rectangle (2 texels
        /// wider); `YCODE_GPU_FEEDBACK_COPY=whole`: the whole attachment level.
        public var feedbackWholeLevel = ProcessInfo.processInfo.environment["YCODE_GPU_FEEDBACK_COPY"] == "whole"
        /// Seconds between saves of a changed pipeline cache.
        public var pipelineCacheSaveInterval = 15.0
        /// `shutdown()`: seconds the GPU may take to finish submitted work
        /// before the completion thread abandons it (stage8-contract.md §12).
        public var shutdownGrace = 10.0
        /// A submission still running after this many seconds is logged
        /// once with a description of its command buffer
        /// (`YCODE_GPU_HANG_REPORT_S`, default 2; VulkanHangReport.swift).
        public var hangReportSeconds = ProcessInfo.processInfo.environment["YCODE_GPU_HANG_REPORT_S"].flatMap { Double($0) } ?? 2
        /// Recording without per-submission diagnostic strings (shader
        /// names, dispatch notes, draw counts in the label; a hang report
        /// describes the command buffer instead) and with argument tables
        /// written from the bound slots only. `YCODE_METAL_RECORD_FAST=0`:
        /// as before, including a read of the process environment on every
        /// draw (stage8-contract.md §15).
        public var recordFast = ProcessInfo.processInfo.environment["YCODE_METAL_RECORD_FAST"] != "0"
        public init() {}
    }

    public let isAvailable: Bool
    /// Why there is no device (nil when available).
    public let unavailableReason: String?
    public let deviceName: String
    public let options: Options

    let ctx: UnsafeMutablePointer<yvk_context>
    let fn: yvk_dispatch
    let translator: ShaderTranslator?
    /// The lock for every table below (and the completion condition).
    let cond = NSCondition()

    // Objects.
    var buffers: [MetalHandle: VKBuffer] = [:]
    var textures: [MetalHandle: VKTexture] = [:]
    var samplers: [MetalHandle: VKSampler] = [:]
    var samplerCache: [SamplerKey: VKSampler] = [:]
    var depthStencilStates: [MetalHandle: MetalDepthStencilDescriptor] = [:]
    var functions: [MetalHandle: VKFunction] = [:]
    var renderPipelines: [MetalHandle: VKRenderPipeline] = [:]
    var computePipelines: [MetalHandle: VKComputePipeline] = [:]
    var events: [MetalHandle: VKEvent] = [:]
    var imports: [AllocationKey: VKAllocation] = [:]
    var imageReferences: [ObjectIdentifier: Int] = [:]
    var formatCache: [UInt32: VulkanPixelFormat?] = [:]
    var textureIndices: IndexAllocator
    var samplerIndices: IndexAllocator
    var dummyImage: VKImage?
    var dummyView: VkImageView?
    var defaultSampler: VkSampler?
    /// 64 KiB of zeros that unknown buffer handles point at.
    var dummyBuffer = yvk_buffer()
    var dummyBufferAddress: UInt64 { dummyBuffer.address }

    // Translation cache (own lock: translation runs outside `cond`).
    let translationLock = NSLock()
    var translations: [TranslationKey: TranslatedShader] = [:]

    // Submission.
    var timeline: VkSemaphore?
    var lastSubmitted: UInt64 = 0
    var completedSerial: UInt64 = 0
    var setup: Recording?
    var freeCommandBuffers: [VkCommandBuffer] = []
    var freeChunks: [TransientChunk] = []
    var pending: [PendingSubmission] = []
    var graveyard: [(serial: UInt64, action: () -> Void)] = []
    var deviceLost = false
    var running = true
    var completionThread: Thread?
    /// Set by `shutdown()`: after this (monotonic ns) the completion thread
    /// stops waiting for the GPU. Under the lock.
    var shutdownDeadline: UInt64 = .max
    /// The completion thread gave up on work the GPU had not finished at
    /// shutdown. Under the lock.
    var abandonedAtShutdown = false
    var statistics = VulkanBackendStatistics()
    /// Diagnostics: skipped commands by the replay source line that skipped them.
    var skipLines: [Int: Int] = [:]

    // Pipelines (VulkanPipelines.swift).
    let compileQueue = OperationQueue()
    let libraries = PipelineLibraryCache()
    var pipelineCacheDirty = false
    var cacheTimer: DispatchSourceTimer?

    struct PendingSubmission {
        var serial: UInt64
        var cb: VkCommandBuffer?
        var chunks: [TransientChunk]
        var status: Int
        var scheduled: (@Sendable () -> Void)?
        var completed: (@Sendable (Int) -> Void)?
        /// Runs on the completion thread after the GPU finished (always called).
        var after: ((_ ok: Bool) -> Void)?
        /// When it was queued (monotonic ns; diagnostics).
        var queuedAt: UInt64 = DispatchTime.now().uptimeNanoseconds
        /// What it is (diagnostics): the client process and command buffer.
        var label: String = ""
        /// Its frame-trace line (`YCODE_METAL_TRACE`).
        var trace: FrameTraceInfo?
        /// The Metal command buffer (hang and device-loss reports).
        var commandBuffer: MetalCommandBuffer?
    }

    /// Writes to each IOSurface plane's memory (copy-outs, host writes):
    /// an image whose recorded generation differs copies the surface in.
    var surfaceGenerations: [SurfaceSyncKey: UInt64] = [:]
    /// `scheduled` handlers of submitted command buffers, called outside the lock.
    var earlyScheduledQueue: [@Sendable () -> Void] = []
    let flushingScheduled = NSLock()
    /// A flusher is running a list it took from `earlyScheduledQueue` (under the lock).
    var scheduledFlushRunning = false
    /// The last serial that copies back to each IOSurface (by surface ID).
    var surfaceWriteSerials: [UInt32: UInt64] = [:]
    /// The timeline value when a surface-write wait last timed out without
    /// progress (nil: none); waits are skipped while the value stays there.
    var surfaceWaitStuckAt: UInt64?

    /// Invalid buffer↔image copies still to be logged (VulkanCommandReplay.swift).
    var invalidCopyLogBudget = 20

    /// Diagnostics: `YCODE_GPU_DAMAGE_LOG=<n>` logs the first n IOSurface render-pass writes.
    var damageLogBudget = Int(ProcessInfo.processInfo.environment["YCODE_GPU_DAMAGE_LOG"] ?? "") ?? 0

    /// The GPU frame trace (`YCODE_METAL_TRACE=<file>`; VulkanFrameTrace.swift).
    var frameTrace: FrameTrace?

    /// Diagnostics (`YCODE_METAL_RECORD_PROFILE=1`): host ns spent in the
    /// parts of recording a command buffer, by `RecordPart`. Under the lock.
    let recordProfiling = ProcessInfo.processInfo.environment["YCODE_METAL_RECORD_PROFILE"] == "1"
    var recordProfile = [UInt64](repeating: 0, count: RecordPart.allCases.count)
    var recordProfileCounts = [Int](repeating: 0, count: RecordPart.allCases.count)

    /// Feedback snapshots (VulkanCommandReplay.swift): copy images by format,
    /// size and swizzle, and the texture slots that point at one during a pass.
    var feedbackCopies: [String: VKTexture] = [:]
    var textureOverride: [MetalHandle: UInt32] = [:]

    // Hang and device-loss reports (VulkanHangReport.swift).
    var checkpointRecords: [CheckpointRecord] = []
    var nextCheckpointID: UInt32 = 1
    var deviceLossReported = false

    // Held work (VulkanEventWaits.swift).
    var held: [HeldKey: [HeldItem]] = [:]
    var heldSince: [HeldKey: UInt64] = [:]
    var heldReported: [HeldKey: UInt64] = [:]
    var heldGraveyard: [() -> Void] = []
    var heldThread: Thread?

    struct TranslationKey: Hashable {
        var hash: UInt64, count: Int, linked: UInt64, linkedCount: Int
    }

    public init(translator: ShaderTranslator? = nil, options: Options = Options()) {
        self.options = options
        self.translator = translator ?? AircProcessTranslator.locate().map {
            AircTranslatorPool(executable: $0, count: options.translatorProcesses)
        }
        compileQueue.maxConcurrentOperationCount = max(options.compileThreads, 1)
        compileQueue.name = "ycode-vulkan-pipelines"
        ctx = .allocate(capacity: 1)
        ctx.initialize(to: yvk_context())
        var opts = yvk_context_options(maxSampledImages: options.maxSampledImages, maxSamplers: options.maxSamplers,
                                       maxStorageImages: options.maxStorageImages, validation: options.validation ? 1 : 0)
        var err = [CChar](repeating: 0, count: 512)
        let r = yvk_context_create(ctx, &opts, &err, err.count)
        fn = yvk_fns().pointee
        if r != 0 {
            isAvailable = false
            unavailableReason = cString(err)
            deviceName = ""
            textureIndices = IndexAllocator(capacity: 0)
            samplerIndices = IndexAllocator(capacity: 0)
            return
        }
        deviceName = withUnsafeBytes(of: ctx.pointee.properties.deviceName) { raw in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
        textureIndices = IndexAllocator(capacity: min(ctx.pointee.heapSampledImages, max(ctx.pointee.heapStorageImages, 1) << 8))
        samplerIndices = IndexAllocator(capacity: ctx.pointee.heapSamplers)
        timeline = yvk_timeline_create(ctx, 0)
        isAvailable = timeline != nil
        unavailableReason = timeline == nil ? "timeline semaphore creation failed" : nil
        guard isAvailable else { return }
        do {
            try createDummies()
        } catch {
            log("dummy resources: \(error)")
        }
        let thread = Thread { [unowned self] in self.completionLoop() }
        thread.name = "ycode-vulkan-completion"
        completionThread = thread
        thread.start()
        loadPipelineCache()
        if let path = ProcessInfo.processInfo.environment["YCODE_METAL_TRACE"], !path.isEmpty {
            frameTrace = FrameTrace(path: path, ctx: ctx, fn: fn)
            log(frameTrace == nil ? "frame trace: cannot write \(path) or no timestamp queries" : "frame trace: \(path)")
        }
        // The translator processes load in the background, so that the
        // first pipeline does not wait for them (YCODE_AIRC_PRESTART=0: at
        // the first request, as before).
        if ProcessInfo.processInfo.environment["YCODE_AIRC_PRESTART"] != "0" {
            (self.translator as? AircTranslatorPool)?.prestart()
        }
    }

    /// The ordered end of the backend (stage8-contract.md §12): finishes the
    /// pipeline compiles, saves the pipeline cache, lets the GPU finish
    /// submitted work (at most `Options.shutdownGrace` seconds), stops the
    /// completion and held-work threads, waits for the device to be idle
    /// and frees it. Afterwards no backend thread is inside the driver, so
    /// the process may call exit(). Work still running at the grace limit
    /// is abandoned: then nothing is freed (freeing objects the GPU still
    /// uses is undefined) and the driver's own teardown at exit cleans up.
    /// Idempotent; later calls return at once.
    public func shutdown() {
        cond.lock()
        let first = running
        cond.unlock()
        guard first else { return }
        if isAvailable {
            compileQueue.waitUntilAllOperationsAreFinished()
            cacheTimer?.cancel()
            savePipelineCache()
            if verbose && usesPipelineLibraries { log("pipeline libraries: \(pipelineLibraryStatistics.summary)") }
        }
        let grace = UInt64(max(options.shutdownGrace, 0) * 1e9)
        cond.lock()
        guard running else { cond.unlock(); return }
        running = false
        let now = DispatchTime.now().uptimeNanoseconds
        shutdownDeadline = now &+ grace
        cond.broadcast()
        cond.unlock()
        guard isAvailable else {
            yvk_context_destroy(ctx)
            return
        }
        // The completion thread waits for the GPU in steps of 1 s and stops
        // at the deadline, so both threads end by about deadline + 1 s.
        let threadsDeadline = now &+ grace &+ 5_000_000_000
        var threadsDone = false
        while true {
            threadsDone = threadsStopped
            if threadsDone || DispatchTime.now().uptimeNanoseconds >= threadsDeadline { break }
            usleep(1000)
        }
        cond.lock()
        let abandoned = abandonedAtShutdown
        cond.unlock()
        guard threadsDone, !abandoned else {
            log("shutdown: " + (threadsDone ? "GPU work abandoned" : "backend threads still running")
                + "; the device is left to the driver's exit teardown")
            return
        }
        _ = fn.vkDeviceWaitIdle!(ctx.pointee.device)
        destroyEverything()
        yvk_context_destroy(ctx)
    }

    /// True once the completion and held-work threads have ended.
    var threadsStopped: Bool {
        cond.lock()
        defer { cond.unlock() }
        return completionThread == nil && heldThread == nil
    }

    /// True after `shutdown()` gave up on unfinished GPU work (tests, diagnostics).
    public var abandonedWorkAtShutdown: Bool {
        cond.lock()
        defer { cond.unlock() }
        return abandonedAtShutdown
    }

    deinit {
        shutdown()
        ctx.deallocate()
    }

    /// YCODE_VULKAN_SKIP_DRAWS=1 (debugging): record no draws. Read once:
    /// `ProcessInfo.environment` builds a dictionary of the whole
    /// environment on every call (it cost about 30 µs per draw when it was
    /// read in the draw path; stage8-contract.md §15).
    var skipDraws: Bool {
        // `YCODE_METAL_RECORD_FAST=0` reads it on every draw as before (A/B of §15).
        options.recordFast ? Self.environmentSkipDraws : ProcessInfo.processInfo.environment["YCODE_VULKAN_SKIP_DRAWS"] != nil
    }
    static let environmentSkipDraws = ProcessInfo.processInfo.environment["YCODE_VULKAN_SKIP_DRAWS"] != nil

    /// YCODE_VULKAN_LOG=1: log object creation details (read once).
    var verbose: Bool { Self.environmentVerbose }
    static let environmentVerbose = ProcessInfo.processInfo.environment["YCODE_VULKAN_LOG"] != nil
    /// YCODE_VULKAN_DUMP_FUNCTIONS=<dir> (read once).
    static let environmentDumpFunctions = ProcessInfo.processInfo.environment["YCODE_VULKAN_DUMP_FUNCTIONS"]

    func log(_ message: String) {
        options.log?("[vulkan] " + message)
    }

    var device: VkDevice? { ctx.pointee.device }

    // MARK: - MetalBackend: device

    public func limits() -> MetalLimits {
        guard isAvailable else { return MetalLimits() }
        let l = ctx.pointee.properties.limits
        let maxInv = UInt64(min(l.maxComputeWorkGroupInvocations, 1024))
        return MetalLimits(maxThreadsPerThreadgroup: (min(UInt64(l.maxComputeWorkGroupSize.0), maxInv),
                                                      min(UInt64(l.maxComputeWorkGroupSize.1), maxInv),
                                                      min(UInt64(l.maxComputeWorkGroupSize.2), maxInv)),
                           maxThreadgroupMemoryLength: UInt64(min(l.maxComputeSharedMemorySize, 32768)))
    }

    /// The Vulkan device's subgroup size (Metal's thread execution width).
    public var subgroupSize: Int { Int(ctx.pointee.subgroupSize) }

    /// The Vulkan pixel format a Metal pixel format gets on this device, nil
    /// when unsupported.
    public func vulkanFormat(forMetal metal: UInt32) -> VulkanPixelFormat? {
        cond.lock(); defer { cond.unlock() }
        return resolveFormat(metal)
    }

    func resolveFormat(_ metal: UInt32) -> VulkanPixelFormat? {
        if let cached = formatCache[metal] { return cached }
        var result: VulkanPixelFormat?
        if var f = metalPixelFormatTable(metal) {
            let usable = { (f: VulkanPixelFormat) -> Bool in
                let feats = yvk_format_features(self.ctx, f.format)
                if f.isDepth || f.isStencil { return feats & VK_FORMAT_FEATURE_DEPTH_STENCIL_ATTACHMENT_BIT.rawValue != 0 }
                return feats & (VK_FORMAT_FEATURE_SAMPLED_IMAGE_BIT.rawValue | VK_FORMAT_FEATURE_COLOR_ATTACHMENT_BIT.rawValue) != 0
            }
            if metal == 1 && (!(ctx.pointee.features.formatA8 != 0) || !usable(f)) {
                // A8 stored as R8; views read alpha from red.
                f.format = VK_FORMAT_R8_UNORM
                f.swizzle = VkComponentMapping(r: VK_COMPONENT_SWIZZLE_ZERO, g: VK_COMPONENT_SWIZZLE_ZERO,
                                               b: VK_COMPONENT_SWIZZLE_ZERO, a: VK_COMPONENT_SWIZZLE_R)
                f.approximate = true
            }
            if !usable(f) && f.isStencil {
                let combined = VK_IMAGE_ASPECT_DEPTH_BIT.rawValue | VK_IMAGE_ASPECT_STENCIL_BIT.rawValue
                for alt in [VK_FORMAT_D24_UNORM_S8_UINT, VK_FORMAT_D32_SFLOAT_S8_UINT] where alt != f.format {
                    var g = f
                    g.format = alt
                    g.aspect = combined
                    if metal == 253 || metal == 261 || metal == 262 { g.viewAspect = VK_IMAGE_ASPECT_STENCIL_BIT.rawValue }
                    if usable(g) { f = g; break }
                }
            }
            if usable(f) { result = f }
        }
        formatCache[metal] = result
        return result
    }

    // MARK: - Buffers

    public func createBuffer(_ handle: MetalHandle, length: Int, storage: MetalStorageMode, guestMemory: GuestSharedRegion?) throws {
        guard isAvailable else { throw VulkanBackendError("no GPU") }
        cond.lock(); defer { cond.unlock() }
        let allocation: VKAllocation
        let offset: Int
        if let g = guestMemory {
            (allocation, offset) = try importRegion(g)
        } else {
            var b = yvk_buffer()
            var err = [CChar](repeating: 0, count: 256)
            let kind = storage == .private || storage == .memoryless ? YVK_MEMORY_DEVICE : YVK_MEMORY_HOST
            guard yvk_buffer_create(ctx, VkDeviceSize(max(length, 4)), kind, nil, &b, &err, err.count) == 0 else {
                throw VulkanBackendError(cString(err))
            }
            allocation = VKAllocation(buffer: b, base: b.mapped, key: nil, owner: nil)
            offset = 0
        }
        allocation.references += 1
        if let old = buffers[handle] { releaseBuffer(old) }
        buffers[handle] = VKBuffer(allocation: allocation, offset: offset, length: length, storage: storage)
        statistics.buffers += 1
    }

    /// Imports guest memory (cached by backing object). Returns the
    /// allocation and the region's offset in it.
    func importRegion(_ g: GuestSharedRegion) throws -> (VKAllocation, Int) {
        let align = UInt(ctx.pointee.hostPointerAlignment)
        func range(_ p: UnsafeMutableRawPointer, _ n: Int) -> (UInt, Int) {
            let start = UInt(bitPattern: p) & ~(align - 1)
            let end = (UInt(bitPattern: p) + UInt(max(n, 1)) + align - 1) & ~(align - 1)
            return (start, Int(end - start))
        }
        let regionStart = UInt(bitPattern: g.pointer)
        // Prefer one import of the whole backing object, with slack around
        // it when the host memory there can be imported as well (§15.6).
        let whole = range(g.objectPointer, g.objectLength)
        var candidates: [(UInt, Int)] = []
        let slack = UInt(max(0, options.importSlack)) & ~(align - 1)
        if slack > 0, let (w0, wlen) = options.importSlackWindow {
            // Clipped to the window (both ends aligned): no slack outside it.
            let lo = max(whole.0 &- slack, (w0 + align - 1) & ~(align - 1))
            let hi = min(whole.0 + UInt(whole.1) + slack, (w0 + wlen) & ~(align - 1))
            if whole.0 >= slack, lo < whole.0 || hi > whole.0 + UInt(whole.1), lo <= whole.0, hi >= whole.0 + UInt(whole.1) {
                candidates.append((lo, Int(hi - lo)))
            }
        }
        candidates.append(whole)
        let tight = range(g.pointer, g.length)
        if tight != whole { candidates.append(tight) }
        var lastError = ""
        for (start, length) in candidates where regionStart >= start && regionStart + UInt(g.length) <= start + UInt(length) {
            let key = AllocationKey(objectID: g.objectID, start: start, length: length)
            if let a = imports[key] { return (a, Int(regionStart - start)) }
            // A cached import of the object that contains this region also serves.
            if let a = imports.first(where: { $0.key.objectID == g.objectID && $0.key.start <= regionStart &&
                                               regionStart + UInt(g.length) <= $0.key.start + UInt($0.key.length) })?.value {
                return (a, Int(regionStart - a.key!.start))
            }
            var b = yvk_buffer()
            var err = [CChar](repeating: 0, count: 256)
            let ptr = UnsafeMutableRawPointer(bitPattern: start)
            if yvk_buffer_create(ctx, VkDeviceSize(length), YVK_MEMORY_IMPORT_HOST, ptr, &b, &err, err.count) == 0 {
                let a = VKAllocation(buffer: b, base: ptr, key: key, owner: g.owner)
                imports[key] = a
                statistics.imports += 1
                if start < whole.0 || start + UInt(length) > whole.0 + UInt(whole.1) { statistics.slackImports += 1 }
                return (a, Int(regionStart - start))
            }
            lastError = cString(err)
        }
        throw VulkanBackendError("import of guest memory \(g.pointer) (+\(g.length)) failed: \(lastError)")
    }

    func releaseAllocationReference(_ a: VKAllocation) {
        a.references -= 1
        guard a.references <= 0 else { return }
        if let key = a.key { imports[key] = nil }
        deferDestroy { [ctx] in yvk_buffer_destroy(ctx, &a.buffer) }
    }

    func releaseBuffer(_ b: VKBuffer) {
        releaseAllocationReference(b.allocation)
    }

    public func gpuAddress(ofBuffer handle: MetalHandle) -> UInt64? {
        cond.lock(); defer { cond.unlock() }
        return buffers[handle]?.address
    }

    // MARK: - Textures

    public func createTexture(_ handle: MetalHandle, _ desc: MetalTextureDescriptor, iosurface: IOSurfaceBacking?) throws {
        guard isAvailable else { throw VulkanBackendError("no GPU") }
        cond.lock(); defer { cond.unlock() }
        guard let fmt = resolveFormat(desc.pixelFormat) else {
            throw VulkanBackendError("pixel format \(desc.pixelFormat) is not supported")
        }
        let type = desc.textureType
        let isCube = type == MetalTextureType.typeCube || type == MetalTextureType.typeCubeArray
        let is3D = type == MetalTextureType.type3D
        let is1D = type == MetalTextureType.type1D || type == MetalTextureType.type1DArray
        let isArray = type == MetalTextureType.type1DArray || type == MetalTextureType.type2DArray ||
            type == MetalTextureType.typeCubeArray || type == MetalTextureType.type2DMultisampleArray
        let layers = (isArray ? max(desc.arrayLength, 1) : 1) * (isCube ? 6 : 1)
        let samples = max(desc.sampleCount, 1)
        let width = max(desc.width, 1), height = is1D ? 1 : max(desc.height, 1), depth = is3D ? max(desc.depth, 1) : 1
        let levels = max(desc.mipmapLevelCount, 1)

        let feats = yvk_format_features(ctx, fmt.format)
        var usage = VK_IMAGE_USAGE_TRANSFER_SRC_BIT.rawValue | VK_IMAGE_USAGE_TRANSFER_DST_BIT.rawValue
        if feats & VK_FORMAT_FEATURE_SAMPLED_IMAGE_BIT.rawValue != 0 { usage |= VK_IMAGE_USAGE_SAMPLED_BIT.rawValue }
        if fmt.isColor && feats & VK_FORMAT_FEATURE_COLOR_ATTACHMENT_BIT.rawValue != 0 && !fmt.isCompressed {
            usage |= VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT.rawValue
        }
        if !fmt.isColor && feats & VK_FORMAT_FEATURE_DEPTH_STENCIL_ATTACHMENT_BIT.rawValue != 0 {
            usage |= VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT.rawValue
        }
        let wantsStorage = desc.usage & MetalTextureUsage.shaderWrite != 0 || desc.usage == 0
        if wantsStorage && samples == 1 && feats & VK_FORMAT_FEATURE_STORAGE_IMAGE_BIT.rawValue != 0 {
            usage |= VK_IMAGE_USAGE_STORAGE_BIT.rawValue
        }
        var flags: UInt32 = 0
        if isCube { flags |= VK_IMAGE_CREATE_CUBE_COMPATIBLE_BIT.rawValue }
        if is3D { flags |= VK_IMAGE_CREATE_2D_ARRAY_COMPATIBLE_BIT.rawValue }
        if fmt.isColor && !fmt.isCompressed { flags |= VK_IMAGE_CREATE_MUTABLE_FORMAT_BIT.rawValue }
        var info = yvk_image_info(type: is3D ? VK_IMAGE_TYPE_3D : (is1D ? VK_IMAGE_TYPE_1D : VK_IMAGE_TYPE_2D),
                                  format: fmt.format, width: UInt32(width), height: UInt32(height), depth: UInt32(depth),
                                  mipLevels: UInt32(levels), arrayLayers: UInt32(layers),
                                  samples: VkSampleCountFlagBits(rawValue: UInt32(samples)), usage: usage, flags: flags)
        var img = yvk_image()
        var err = [CChar](repeating: 0, count: 256)
        guard yvk_image_create(ctx, &info, &img, &err, err.count) == 0 else { throw VulkanBackendError(cString(err)) }
        let image = VKImage(image: img, format: fmt, metalFormat: desc.pixelFormat, imageType: info.type, width: width,
                            height: height, depth: depth, levels: levels, layers: layers, samples: samples, usage: usage)
        if let s = iosurface {
            do {
                let (alloc, offset) = try importRegion(s.region)
                alloc.references += 1
                image.surface = SurfaceLink(allocation: alloc, offset: offset + s.planeOffset, bytesPerRow: s.bytesPerRow,
                                            width: min(s.width, width), height: min(s.height, height), surfaceID: s.surfaceID,
                                            limit: max(0, s.region.length - s.planeOffset), syncState: s.syncState)
                if verbose {
                    log("texture \(handle): IOSurface \(s.surfaceID) \(s.width)x\(s.height) pitch \(s.bytesPerRow) bpe \(s.bytesPerElement) " +
                        "format \(String(s.pixelFormat, radix: 16)) bytes \(s.region.length); Metal format \(desc.pixelFormat) \(width)x\(height)")
                }
            } catch {
                yvk_image_destroy(ctx, &image.image)
                throw error
            }
        }
        try initializeImage(image)
        let tex = VKTexture(image: image, format: fmt, metalFormat: desc.pixelFormat, textureType: type, baseLevel: 0,
                            levelCount: levels, baseLayer: 0, layerCount: layers, swizzle: fmt.swizzle, metalUsage: desc.usage)
        imageReferences[ObjectIdentifier(image)] = 1
        makeShaderViews(tex)
        if let old = textures[handle] { releaseTexture(old) }
        textures[handle] = tex
        statistics.textures += 1
    }

    public func createTextureView(_ handle: MetalHandle, parent: MetalHandle, _ desc: MetalTextureViewDescriptor) throws {
        guard isAvailable else { throw VulkanBackendError("no GPU") }
        cond.lock(); defer { cond.unlock() }
        guard let p = textures[parent] else { throw VulkanBackendError("texture view of unknown texture \(parent)") }
        guard let fmt = resolveFormat(desc.pixelFormat == 0 ? p.metalFormat : desc.pixelFormat) else {
            throw VulkanBackendError("pixel format \(desc.pixelFormat) is not supported")
        }
        let levels = desc.levels ?? 0..<p.levelCount
        let slices = desc.slices ?? 0..<p.layerCount
        let type = desc.textureType ?? p.textureType
        // Metal view slices are 2D slices (cube faces count one each).
        var outer = identitySwizzle
        if let s = desc.swizzle, s.count == 4 {
            outer = VkComponentMapping(r: vkSwizzle(s[0]), g: vkSwizzle(s[1]), b: vkSwizzle(s[2]), a: vkSwizzle(s[3]))
        }
        let tex = VKTexture(image: p.image, format: fmt, metalFormat: desc.pixelFormat == 0 ? p.metalFormat : desc.pixelFormat,
                            textureType: type, baseLevel: p.baseLevel + levels.lowerBound, levelCount: max(levels.count, 1),
                            baseLayer: p.baseLayer + slices.lowerBound, layerCount: max(slices.count, 1),
                            swizzle: composeSwizzle(outer, over: fmt.swizzle), metalUsage: p.metalUsage)
        imageReferences[ObjectIdentifier(p.image), default: 0] += 1
        makeShaderViews(tex)
        if let old = textures[handle] { releaseTexture(old) }
        textures[handle] = tex
    }

    /// Moves a new image to GENERAL (recorded into the setup command buffer).
    func initializeImage(_ image: VKImage) throws {
        let rec = try setupRecording()
        yvk_cmd_image_layout(rec.cb, image.vkImage, image.format.aspect, VK_IMAGE_LAYOUT_UNDEFINED, VK_IMAGE_LAYOUT_GENERAL)
        rec.empty = false
        image.initialized = true
    }

    func viewType(for tex: VKTexture) -> VkImageViewType {
        switch tex.textureType {
        case MetalTextureType.type1D: return tex.layerCount > 1 ? VK_IMAGE_VIEW_TYPE_1D_ARRAY : VK_IMAGE_VIEW_TYPE_1D
        case MetalTextureType.type1DArray: return VK_IMAGE_VIEW_TYPE_1D_ARRAY
        case MetalTextureType.type2DArray, MetalTextureType.type2DMultisampleArray: return VK_IMAGE_VIEW_TYPE_2D_ARRAY
        case MetalTextureType.typeCube: return VK_IMAGE_VIEW_TYPE_CUBE
        case MetalTextureType.typeCubeArray: return VK_IMAGE_VIEW_TYPE_CUBE_ARRAY
        case MetalTextureType.type3D: return VK_IMAGE_VIEW_TYPE_3D
        default: return VK_IMAGE_VIEW_TYPE_2D
        }
    }

    /// Creates the sampled and storage views of a texture and gives it a heap index.
    func makeShaderViews(_ tex: VKTexture) {
        let image = tex.image
        guard tex.textureType != MetalTextureType.typeTextureBuffer else { return }
        var err = [CChar](repeating: 0, count: 256)
        if image.usage & VK_IMAGE_USAGE_SAMPLED_BIT.rawValue != 0,
           yvk_format_features(ctx, tex.format.format) & VK_FORMAT_FEATURE_SAMPLED_IMAGE_BIT.rawValue != 0 {
            var vi = yvk_view_info(image: image.vkImage, viewType: viewType(for: tex), format: tex.format.format,
                                   aspect: tex.format.viewAspect, baseLevel: UInt32(tex.baseLevel),
                                   levelCount: UInt32(tex.levelCount), baseLayer: UInt32(tex.baseLayer),
                                   layerCount: UInt32(tex.layerCount), components: tex.swizzle,
                                   usage: VK_IMAGE_USAGE_SAMPLED_BIT.rawValue)
            tex.shaderView = yvk_view_create(ctx, &vi, &err, err.count)
            if tex.shaderView == nil { log("sampled view: \(cString(err))") }
        }
        if image.usage & VK_IMAGE_USAGE_STORAGE_BIT.rawValue != 0, tex.swizzle == identitySwizzle,
           yvk_format_features(ctx, tex.format.format) & VK_FORMAT_FEATURE_STORAGE_IMAGE_BIT.rawValue != 0 {
            var vi = yvk_view_info(image: image.vkImage, viewType: viewType(for: tex), format: tex.format.format,
                                   aspect: tex.format.viewAspect, baseLevel: UInt32(tex.baseLevel),
                                   levelCount: UInt32(tex.levelCount), baseLayer: UInt32(tex.baseLayer),
                                   layerCount: UInt32(tex.layerCount), components: identitySwizzle,
                                   usage: VK_IMAGE_USAGE_STORAGE_BIT.rawValue)
            tex.storageView = yvk_view_create(ctx, &vi, &err, err.count)
        }
        guard tex.shaderView != nil || tex.storageView != nil, let index = textureIndices.allocate() else { return }
        tex.heapIndex = index
        if let v = tex.shaderView { yvk_heap_write_sampled(ctx, index, v) }
        if let v = tex.storageView { yvk_heap_write_storage(ctx, index, v) }
    }

    /// A single-level, single-layer view for rendering into or copying.
    func attachmentView(_ tex: VKTexture, level: Int, slice: Int) -> VkImageView? {
        let key = level << 20 | slice
        if let v = tex.attachmentViews[key] { return v }
        let image = tex.image
        let attachmentUsage = tex.format.isColor ? VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT.rawValue
            : VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT.rawValue
        guard image.usage & attachmentUsage != 0 else { return nil }
        var vi = yvk_view_info(image: image.vkImage, viewType: VK_IMAGE_VIEW_TYPE_2D, format: tex.format.format,
                               aspect: tex.format.aspect, baseLevel: UInt32(tex.baseLevel + level), levelCount: 1,
                               baseLayer: UInt32(image.imageType == VK_IMAGE_TYPE_3D ? slice : tex.baseLayer + slice),
                               layerCount: 1, components: identitySwizzle, usage: attachmentUsage)
        var err = [CChar](repeating: 0, count: 256)
        let v = yvk_view_create(ctx, &vi, &err, err.count)
        if v == nil { log("attachment view: \(cString(err))") }
        tex.attachmentViews[key] = v
        return v
    }

    func releaseTexture(_ tex: VKTexture) {
        let views = [tex.shaderView, tex.storageView].compactMap { $0 } + Array(tex.attachmentViews.values.compactMap { $0 })
        let index = tex.heapIndex
        let image = tex.image
        let id = ObjectIdentifier(image)
        imageReferences[id, default: 1] -= 1
        let destroyImage = imageReferences[id]! <= 0
        if destroyImage {
            imageReferences[id] = nil
            if let s = image.surface { releaseAllocationReference(s.allocation) }
        }
        deferDestroy { [ctx, fn, weak self] in
            for v in views { fn.vkDestroyImageView!(ctx.pointee.device, v, nil) }
            if index != 0 { self?.textureIndices.release(index) }
            if destroyImage { yvk_image_destroy(ctx, &image.image) }
        }
    }

    // MARK: - Samplers and depth-stencil states

    public func createSampler(_ handle: MetalHandle, _ desc: MetalSamplerDescriptor) throws {
        guard isAvailable else { throw VulkanBackendError("no GPU") }
        cond.lock(); defer { cond.unlock() }
        samplers[handle] = try sampler(for: SamplerKey(desc))
    }

    func sampler(for key: SamplerKey) throws -> VKSampler {
        if let s = samplerCache[key] { return s }
        guard let index = samplerIndices.allocate() else { throw VulkanBackendError("sampler heap is full") }
        var info = samplerInfo(key)
        var err = [CChar](repeating: 0, count: 256)
        guard let s = yvk_sampler_create(ctx, &info, &err, err.count) else {
            samplerIndices.release(index)
            throw VulkanBackendError(cString(err))
        }
        yvk_heap_write_sampler(ctx, index, s)
        let v = VKSampler(sampler: s, heapIndex: index, key: key)
        samplerCache[key] = v
        statistics.samplers += 1
        return v
    }

    func samplerInfo(_ k: SamplerKey) -> yvk_sampler_info {
        let mirror = ctx.pointee.features.samplerMirrorClampToEdge != 0
        var i = yvk_sampler_info()
        i.magFilter = k.magFilter == 1 ? VK_FILTER_LINEAR : VK_FILTER_NEAREST
        i.minFilter = k.minFilter == 1 ? VK_FILTER_LINEAR : VK_FILTER_NEAREST
        i.mipmapMode = k.mipFilter == 2 ? VK_SAMPLER_MIPMAP_MODE_LINEAR : VK_SAMPLER_MIPMAP_MODE_NEAREST
        i.addressU = vkAddressMode(k.s, mirrorClampSupported: mirror)
        i.addressV = vkAddressMode(k.t, mirrorClampSupported: mirror)
        i.addressW = vkAddressMode(k.r, mirrorClampSupported: mirror)
        i.minLod = max(k.lodMin, 0)
        i.maxLod = min(k.lodMax, 1000)
        if k.mipFilter == 0 {
            // Not mipmapped: level 0 only (the Vulkan spec's recommended emulation).
            i.minLod = 0
            i.maxLod = 0.25
        }
        i.borderColor = [k.s, k.t, k.r].contains(5) ? vkBorderColor(k.border) : VK_BORDER_COLOR_FLOAT_TRANSPARENT_BLACK
        i.compareEnable = k.compare != 0 ? 1 : 0
        i.compareOp = vkCompare(k.compare)
        i.maxAnisotropy = Float(max(k.anisotropy, 1))
        i.anisotropyEnable = k.anisotropy > 1 ? 1 : 0
        if !k.normalized {
            i.unnormalizedCoordinates = 1
            i.minFilter = i.magFilter
            i.mipmapMode = VK_SAMPLER_MIPMAP_MODE_NEAREST
            i.minLod = 0
            i.maxLod = 0
            i.anisotropyEnable = 0
            i.compareEnable = 0
            for p in [\yvk_sampler_info.addressU, \yvk_sampler_info.addressV, \yvk_sampler_info.addressW]
            where i[keyPath: p] != VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_BORDER {
                i[keyPath: p] = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE
            }
        }
        return i
    }

    public func gpuResourceID(ofSampler handle: MetalHandle) -> UInt64? {
        cond.lock(); defer { cond.unlock() }
        return samplers[handle].map { UInt64($0.heapIndex) }
    }

    public func createDepthStencilState(_ handle: MetalHandle, _ desc: MetalDepthStencilDescriptor) throws {
        cond.lock(); defer { cond.unlock() }
        depthStencilStates[handle] = desc
    }

    // MARK: - Functions and pipelines

    public func createFunction(_ handle: MetalHandle, metallib: [UInt8]) throws {
        cond.lock(); defer { cond.unlock() }
        functions[handle] = VKFunction(metallib: metallib)
        // Debugging: YCODE_VULKAN_DUMP_FUNCTIONS=<dir> saves each function as sent.
        if let dir = Self.environmentDumpFunctions {
            let path = "\(dir)/function-\(handle.raw)-\(String(fnv1a64(metallib), radix: 16)).metallib"
            FileManager.default.createFile(atPath: path, contents: Data(metallib))
        }
    }

    // Translation and pipelines: VulkanPipelines.swift.

    // MARK: - Events

    public func createEvent(_ handle: MetalHandle) throws {
        guard isAvailable else { return }
        cond.lock(); defer { cond.unlock() }
        events[handle] = VKEvent(semaphore: yvk_timeline_create(ctx, 0))
    }

    public func signalEvent(_ handle: MetalHandle, value: UInt64) {
        cond.lock(); defer { cond.unlock() }
        guard let e = events[handle], let s = e.semaphore else { return }
        if value > yvk_timeline_value(ctx, s) && value > e.highest {
            _ = yvk_timeline_signal(ctx, s, value)
            e.highest = value
        }
    }

    public func eventValue(_ handle: MetalHandle) -> UInt64? {
        cond.lock(); defer { cond.unlock() }
        guard let e = events[handle], let s = e.semaphore else { return nil }
        return yvk_timeline_value(ctx, s)
    }

    // MARK: - Release

    public func release(_ handle: MetalHandle) {
        cond.lock(); defer { cond.unlock() }
        if let b = buffers.removeValue(forKey: handle) { releaseBuffer(b); return }
        if let t = textures.removeValue(forKey: handle) { releaseTexture(t); return }
        if samplers.removeValue(forKey: handle) != nil { return }  // samplers stay cached (deduplicated)
        if depthStencilStates.removeValue(forKey: handle) != nil { return }
        if functions.removeValue(forKey: handle) != nil { return }
        if let p = renderPipelines.removeValue(forKey: handle) { releaseRenderPipeline(p); return }
        if let p = computePipelines.removeValue(forKey: handle) { releaseComputePipeline(p); return }
        if let e = events.removeValue(forKey: handle), let s = e.semaphore {
            deferDestroy { [ctx, fn] in fn.vkDestroySemaphore!(ctx.pointee.device, s, nil) }
        }
    }

    /// Runs `action` once all work submitted so far (including pending
    /// setup work) has completed.
    func deferDestroy(_ action: @escaping () -> Void) {
        // Held work may still use the object: after it is submitted.
        if !held.isEmpty {
            heldGraveyard.append(action)
            return
        }
        let serial = (setup?.empty == false) ? lastSubmitted + 1 : lastSubmitted
        if serial <= completedSerial {
            action()
        } else {
            graveyard.append((serial, action))
        }
    }

    // MARK: - Dummy resources

    func createDummies() throws {
        cond.lock(); defer { cond.unlock() }
        var info = yvk_image_info(type: VK_IMAGE_TYPE_2D, format: VK_FORMAT_R8G8B8A8_UNORM, width: 1, height: 1, depth: 1,
                                  mipLevels: 1, arrayLayers: 1, samples: VK_SAMPLE_COUNT_1_BIT,
                                  usage: VK_IMAGE_USAGE_SAMPLED_BIT.rawValue | VK_IMAGE_USAGE_STORAGE_BIT.rawValue |
                                      VK_IMAGE_USAGE_TRANSFER_DST_BIT.rawValue, flags: 0)
        var img = yvk_image()
        var err = [CChar](repeating: 0, count: 256)
        guard yvk_image_create(ctx, &info, &img, &err, err.count) == 0 else { throw VulkanBackendError(cString(err)) }
        let image = VKImage(image: img, format: metalPixelFormatTable(70)!, metalFormat: 70, imageType: VK_IMAGE_TYPE_2D,
                            width: 1, height: 1, depth: 1, levels: 1, layers: 1, samples: 1, usage: info.usage)
        try initializeImage(image)
        let rec = try setupRecording()
        var clear = VkClearColorValue(float32: (0, 0, 0, 0))
        var range = VkImageSubresourceRange(aspectMask: VK_IMAGE_ASPECT_COLOR_BIT.rawValue, baseMipLevel: 0, levelCount: 1,
                                            baseArrayLayer: 0, layerCount: 1)
        fn.vkCmdClearColorImage!(rec.cb, image.vkImage, VK_IMAGE_LAYOUT_GENERAL, &clear, 1, &range)
        dummyImage = image
        var vi = yvk_view_info(image: image.vkImage, viewType: VK_IMAGE_VIEW_TYPE_2D, format: VK_FORMAT_R8G8B8A8_UNORM,
                               aspect: VK_IMAGE_ASPECT_COLOR_BIT.rawValue, baseLevel: 0, levelCount: 1, baseLayer: 0,
                               layerCount: 1, components: identitySwizzle, usage: 0)
        dummyView = yvk_view_create(ctx, &vi, &err, err.count)
        if let v = dummyView {
            yvk_heap_write_sampled(ctx, 0, v)
            yvk_heap_write_storage(ctx, 0, v)
        }
        if yvk_buffer_create(ctx, 65536, YVK_MEMORY_HOST, nil, &dummyBuffer, &err, err.count) == 0, let p = dummyBuffer.mapped {
            p.initializeMemory(as: UInt8.self, repeating: 0, count: 65536)
        }
        var si = samplerInfo(SamplerKey(MetalSamplerDescriptor()))
        defaultSampler = yvk_sampler_create(ctx, &si, &err, err.count)
        if let s = defaultSampler { yvk_heap_write_sampler(ctx, 0, s) }
    }

    func destroyEverything() {
        cond.lock(); defer { cond.unlock() }
        for b in buffers.values { releaseBuffer(b) }
        buffers.removeAll()
        for t in textures.values { releaseTexture(t) }
        textures.removeAll()
        for p in renderPipelines.values { releaseRenderPipeline(p) }
        renderPipelines.removeAll()
        for p in computePipelines.values { releaseComputePipeline(p) }
        computePipelines.removeAll()
        for e in events.values { if let s = e.semaphore { fn.vkDestroySemaphore!(device, s, nil) } }
        events.removeAll()
        for g in graveyard { g.action() }
        graveyard.removeAll()
        for p in libraries.all() { fn.vkDestroyPipeline!(device, p, nil) }
        for t in feedbackCopies.values { releaseTexture(t) }
        feedbackCopies.removeAll()
        for g in graveyard { g.action() }
        graveyard.removeAll()
        for s in samplerCache.values { if let v = s.sampler { fn.vkDestroySampler!(device, v, nil) } }
        samplerCache.removeAll()
        if let s = defaultSampler { fn.vkDestroySampler!(device, s, nil) }
        if let v = dummyView { fn.vkDestroyImageView!(device, v, nil) }
        frameTrace?.destroy(device, fn)
        frameTrace = nil
        if let d = dummyImage { yvk_image_destroy(ctx, &d.image) }
        yvk_buffer_destroy(ctx, &dummyBuffer)
        for c in freeChunks { yvk_buffer_destroy(ctx, &c.buffer) }
        freeChunks.removeAll()
        if let s = setup { for c in s.chunks { yvk_buffer_destroy(ctx, &c.buffer) } }
        setup = nil
        if let t = timeline { fn.vkDestroySemaphore!(device, t, nil) }
        timeline = nil
    }
}

/// The parts of recording a command buffer (`YCODE_METAL_RECORD_PROFILE=1`).
enum RecordPart: Int, CaseIterable {
    case start, surfacesIn, passBegin, drawPrepare, table, renderCommands, passEnd, compute, blit, barriers, surfacesOut, submit, label

    var name: String { "\(self)" }
}

extension VulkanMetalBackend {
    /// Adds the time since `start` to a part (when profiling). Under the lock.
    @inline(__always)
    func profiled(_ part: RecordPart, since start: UInt64) {
        guard recordProfiling else { return }
        recordProfile[part.rawValue] &+= DispatchTime.now().uptimeNanoseconds &- start
        recordProfileCounts[part.rawValue] += 1
    }

    @inline(__always)
    func profileClock() -> UInt64 { recordProfiling ? DispatchTime.now().uptimeNanoseconds : 0 }

    var recordProfileSummary: String {
        RecordPart.allCases.map { p in
            String(format: "%@ %.1f ms/%d", p.name, Double(recordProfile[p.rawValue]) / 1e6, recordProfileCounts[p.rawValue])
        }.joined(separator: ", ")
    }
}

/// Counters for logs and tests.
public struct VulkanBackendStatistics: Sendable {
    public var buffers = 0, textures = 0, samplers = 0, imports = 0
    public var renderPipelines = 0, computePipelines = 0
    public var submissions = 0, draws = 0, dispatches = 0, blits = 0, skipped = 0
    public var surfaceUploads = 0, surfaceDownloads = 0
    /// Metal command buffers completed, and their queue-to-completion
    /// latency (total and largest, ns).
    public var completedCommandBuffers = 0
    public var latencyTotalNs: UInt64 = 0, latencyMaxNs: UInt64 = 0
    /// GPU-side boot cost (diagnostics): translator calls (not answered by
    /// the in-memory cache), whole-pipeline compiles, compute variants,
    /// submissions that waited for a pipeline, and the CPU time spent
    /// recording command buffers under the backend lock.
    public var translations = TimeCounter(), translationHits = 0
    public var renderCompiles = TimeCounter(), computeCompiles = TimeCounter()
    public var pipelineWaits = TimeCounter()
    public var recording = TimeCounter()
    public var surfaceBytesUp = 0, surfaceBytesDown = 0
    /// Copy-ins skipped (the image held the surface's pixels), and the bytes
    /// whole-surface copy-outs would have moved.
    public var surfaceUploadsSkipped = 0, surfaceBytesDownFull = 0
    /// Completion waits that timed out although the GPU had reached the
    /// value (the counter read after the slice found it).
    public var lateWakeups = 0
    /// Command buffers reported scheduled at submission, and CPU accesses
    /// that waited for a pending GPU write to an IOSurface.
    public var earlyScheduled = 0
    public var surfaceWriteWaits = TimeCounter()
    /// Surface-write waits that timed out with the GPU making no progress.
    public var surfaceWriteWaitTimeouts = 0
    /// Dispatches run one thread per workgroup (§15.5).
    public var laneIsolatedDispatches = 0
    /// Guest-memory imports made with slack around the object (§15.6).
    public var slackImports = 0
    /// Copies of a color attachment made for a draw that samples it (§15.6).
    public var feedbackSnapshots = 0
    public var feedbackTexels = 0
    /// Queue-to-completion latency of Metal command buffers: counts below
    /// 1, 2, 4, 8, 16, 33 ms and above.
    public var latencyBuckets = [Int](repeating: 0, count: 7)
    public static let latencyBucketLimitsNs: [UInt64] = [1, 2, 4, 8, 16, 33].map { $0 * 1_000_000 }
}

/// A count with total and largest duration (ns).
public struct TimeCounter: Sendable, CustomStringConvertible {
    public var count = 0
    public var totalNs: UInt64 = 0, maxNs: UInt64 = 0
    public init() {}
    public mutating func add(_ ns: UInt64) {
        count += 1
        totalNs &+= ns
        maxNs = max(maxNs, ns)
    }
    public var description: String {
        String(format: "%d (%.1f ms, max %.1f ms)", count, Double(totalNs) / 1e6, Double(maxNs) / 1e6)
    }
}

extension VulkanMetalBackend {
    public var stats: VulkanBackendStatistics {
        cond.lock(); defer { cond.unlock() }
        return statistics
    }
}

extension VulkanMetalBackend {
    /// Diagnostics (`YCODE_METAL_STATS`): counters, queue depth, pipelines
    /// still building or broken.
    public func diagnosticSummary() -> String? {
        guard isAvailable else { return nil }
        cond.lock()
        let s = statistics
        let queued = pending.count
        let serials = "\(completedSerial)/\(lastSubmitted)"
        let brokenRender = renderPipelines.values.filter { $0.broken || !$0.failed.isEmpty }.count
        let brokenCompute = computePipelines.values.filter { $0.broken || !$0.failed.isEmpty }.count
        let lost = deviceLost
        let skips = skipLines.sorted { $0.key < $1.key }.map { "L\($0.key)×\($0.value)" }.joined(separator: " ")
        cond.unlock()
        return "serials \(serials), \(queued) pending, compile queue \(compileQueue.operationCount), "
            + "\(s.renderPipelines) render / \(s.computePipelines) compute pipelines (broken \(brokenRender) / \(brokenCompute)), "
            + "\(s.submissions) submissions, \(s.draws) draws, \(s.dispatches) dispatches, \(s.blits) blits, \(s.skipped) skipped, "
            + "surface up/down \(s.surfaceUploads)/\(s.surfaceDownloads), \(s.textures) textures, \(s.buffers) buffers, \(s.imports) imports (\(s.slackImports) with slack)"
            + (s.completedCommandBuffers == 0 ? "" : String(format: ", latency avg %.2f ms max %.1f ms",
                                                              Double(s.latencyTotalNs) / Double(s.completedCommandBuffers) / 1e6,
                                                              Double(s.latencyMaxNs) / 1e6))
            + (skips.isEmpty ? "" : " (skips by replay line: \(skips))")
            + (lost ? ", DEVICE LOST" : "")
            + "; translations \(s.translations) + \(s.translationHits) cached, render compiles \(s.renderCompiles), "
            + "compute variants \(s.computeCompiles), pipeline waits \(s.pipelineWaits), recording \(s.recording), "
            + String(format: "surface MB up/down %.0f/%.0f (whole surfaces would be down %.0f; %d copy-ins skipped)",
                     Double(s.surfaceBytesUp) / 1e6, Double(s.surfaceBytesDown) / 1e6, Double(s.surfaceBytesDownFull) / 1e6,
                     s.surfaceUploadsSkipped) + ", \(s.lateWakeups) late wake-ups, \(s.earlyScheduled) scheduled at submission, surface write waits \(s.surfaceWriteWaits) (\(s.surfaceWriteWaitTimeouts) timed out)"
            + ", \(s.laneIsolatedDispatches) lane-isolated dispatches, \(s.feedbackSnapshots) feedback copies (\(s.feedbackTexels / 1_000_000) Mtexels)"
            + ", latency ms <1/<2/<4/<8/<16/<33/more " + s.latencyBuckets.map(String.init).joined(separator: "/")
            + (usesPipelineLibraries ? "; libraries: " + pipelineLibraryStatistics.summary : "")
            + (recordProfiling ? "; recording parts: " + lockedRecordProfileSummary() : "")
    }

    func lockedRecordProfileSummary() -> String {
        cond.lock(); defer { cond.unlock() }
        return recordProfileSummary
    }

    /// Counts a skipped command (under the lock).
    func noteSkip(_ line: Int = #line) {
        statistics.skipped += 1
        skipLines[line, default: 0] += 1
    }
}
