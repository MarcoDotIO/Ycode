// The back end's objects: buffers (guest-shared imports and device
// memory), textures and views, samplers, functions, pipelines, events, and
// the small allocators they use. All access is under VulkanMetalBackend's
// lock.

import CVulkan
import Foundation
import YcodeMetalHost

/// Vulkan memory behind one or more Metal buffers or IOSurfaces. An import
/// of guest memory covers a 4096-aligned range that contains the guest
/// region; several Metal objects over the same guest object share it.
final class VKAllocation {
    var buffer: yvk_buffer
    /// The host address of byte 0 of `buffer` (nil for device memory without a mapping).
    let base: UnsafeMutableRawPointer?
    /// Import-cache key, nil for allocations the back end owns alone.
    let key: AllocationKey?
    var references = 0
    /// Keeps the guest memory alive while imported.
    let owner: AnyObject?

    init(buffer: yvk_buffer, base: UnsafeMutableRawPointer?, key: AllocationKey?, owner: AnyObject?) {
        self.buffer = buffer
        self.base = base
        self.key = key
        self.owner = owner
    }
}

struct AllocationKey: Hashable {
    var objectID: UInt64
    var start: UInt
    var length: Int
}

/// A Metal buffer: a byte range of an allocation.
final class VKBuffer {
    let allocation: VKAllocation
    /// Offset of the Metal buffer's byte 0 in the allocation.
    let offset: Int
    let length: Int
    let storage: MetalStorageMode

    init(allocation: VKAllocation, offset: Int, length: Int, storage: MetalStorageMode) {
        self.allocation = allocation
        self.offset = offset
        self.length = length
        self.storage = storage
    }

    var vkBuffer: VkBuffer? { allocation.buffer.buffer }
    var address: UInt64 { allocation.buffer.address + UInt64(offset) }
    var hostPointer: UnsafeMutableRawPointer? { allocation.buffer.mapped.map { $0 + offset } }
}

/// The memory of an IOSurface a texture lives in (copied in before use and
/// out after writes, see VulkanCommandReplay.swift).
struct SurfaceLink {
    let allocation: VKAllocation
    /// Byte offset of the plane's first pixel in the allocation.
    let offset: Int
    let bytesPerRow: Int
    let width: Int
    let height: Int
    let surfaceID: UInt32
    /// Bytes of surface memory from `offset` on; no copy may go past them.
    let limit: Int
    /// The surface's seed and whether a lock is held (nil: unknown).
    var syncState: (@Sendable () -> (seed: UInt32, locked: Bool)?)?
    /// Identifies the surface plane across images (copy-in tracking).
    var syncKey: SurfaceSyncKey { SurfaceSyncKey(surfaceID: surfaceID, offset: offset) }
}

struct SurfaceSyncKey: Hashable {
    var surfaceID: UInt32
    var offset: Int
}

/// The part of a surface a command buffer can have written (pixels of
/// level 0, half-open), or all of it.
struct SurfaceDamage {
    var isFull = false
    var x0 = Int.max, y0 = Int.max, x1 = Int.min, y1 = Int.min
    static let full = SurfaceDamage(isFull: true)

    init() {}
    init(isFull: Bool) { self.isFull = isFull }
    init(x: Int, y: Int, width: Int, height: Int) {
        if width > 0 && height > 0 { x0 = x; y0 = y; x1 = x + width; y1 = y + height }
    }

    var isEmpty: Bool { !isFull && (x1 <= x0 || y1 <= y0) }

    mutating func add(_ d: SurfaceDamage) {
        if isFull || d.isEmpty { return }
        if d.isFull { self = .full; return }
        x0 = min(x0, d.x0); y0 = min(y0, d.y0); x1 = max(x1, d.x1); y1 = max(y1, d.y1)
    }
}

/// The Vulkan image behind a texture and all its views.
final class VKImage {
    var image: yvk_image
    let format: VulkanPixelFormat
    let metalFormat: UInt32
    let imageType: VkImageType
    let width: Int, height: Int, depth: Int
    let levels: Int, layers: Int
    let samples: Int
    let usage: VkImageUsageFlags
    var surface: SurfaceLink?
    /// The image has been moved to VK_IMAGE_LAYOUT_GENERAL.
    var initialized = false
    /// IOSurface images: the surface generation and seed when the image
    /// last held the surface's pixels (nil: unknown, copy in before use).
    var syncedGeneration: UInt64?
    var syncedSeed: UInt32 = 0

    init(image: yvk_image, format: VulkanPixelFormat, metalFormat: UInt32, imageType: VkImageType, width: Int,
         height: Int, depth: Int, levels: Int, layers: Int, samples: Int, usage: VkImageUsageFlags) {
        self.image = image
        self.format = format
        self.metalFormat = metalFormat
        self.imageType = imageType
        self.width = width
        self.height = height
        self.depth = depth
        self.levels = levels
        self.layers = layers
        self.samples = samples
        self.usage = usage
    }

    var vkImage: VkImage? { image.image }

    func levelSize(_ level: Int) -> (Int, Int, Int) {
        (max(1, width >> level), max(1, height >> level), imageType == VK_IMAGE_TYPE_3D ? max(1, depth >> level) : 1)
    }
}

/// A Metal texture or texture view.
final class VKTexture {
    let image: VKImage
    /// The texture's own format (a view may differ from the image's).
    let format: VulkanPixelFormat
    let metalFormat: UInt32
    let textureType: UInt8
    let baseLevel: Int, levelCount: Int
    let baseLayer: Int, layerCount: Int
    let swizzle: VkComponentMapping
    let metalUsage: UInt16
    /// The full view for shaders, and its heap index (0 = none).
    var shaderView: VkImageView?
    var storageView: VkImageView?
    var heapIndex: UInt32 = 0
    /// Attachment and copy views by (level, layer).
    var attachmentViews: [Int: VkImageView] = [:]

    init(image: VKImage, format: VulkanPixelFormat, metalFormat: UInt32, textureType: UInt8, baseLevel: Int,
         levelCount: Int, baseLayer: Int, layerCount: Int, swizzle: VkComponentMapping, metalUsage: UInt16) {
        self.image = image
        self.format = format
        self.metalFormat = metalFormat
        self.textureType = textureType
        self.baseLevel = baseLevel
        self.levelCount = levelCount
        self.baseLayer = baseLayer
        self.layerCount = layerCount
        self.swizzle = swizzle
        self.metalUsage = metalUsage
    }

    /// Size of the texture's level `level` (relative to the view).
    func levelSize(_ level: Int) -> (Int, Int, Int) { image.levelSize(baseLevel + level) }
}

/// A deduplicated sampler (Vulkan allows only a few thousand sampler objects).
final class VKSampler {
    let sampler: VkSampler?
    let heapIndex: UInt32
    let key: SamplerKey
    init(sampler: VkSampler?, heapIndex: UInt32, key: SamplerKey) {
        self.sampler = sampler
        self.heapIndex = heapIndex
        self.key = key
    }
}

/// The fields of a sampler that matter to Vulkan (a cache key).
struct SamplerKey: Hashable {
    var minFilter: UInt8, magFilter: UInt8, mipFilter: UInt8
    var s: UInt8, t: UInt8, r: UInt8
    var border: UInt8, compare: UInt8, anisotropy: UInt8
    var normalized: Bool
    var lodMin: Float, lodMax: Float

    init(_ d: MetalSamplerDescriptor) {
        minFilter = d.minFilter; magFilter = d.magFilter; mipFilter = d.mipFilter
        s = d.sAddressMode; t = d.tAddressMode; r = d.rAddressMode
        border = d.borderColor; compare = d.compareFunction; anisotropy = d.maxAnisotropy
        normalized = d.normalizedCoordinates
        lodMin = d.lodMinClamp; lodMax = d.lodMaxClamp
    }

    /// A constexpr sampler of ycode-airc's reflection (names → MTLSampler* values).
    init(_ c: ShaderReflection.ConstexprSampler) {
        func address(_ n: String?) -> UInt8 {
            switch n {
            case "mirror_clamp_to_edge": return 1
            case "repeat": return 2
            case "mirrored_repeat": return 3
            case "clamp_to_zero": return 4
            case "clamp_to_border": return 5
            default: return 0
            }
        }
        func filter(_ n: String?) -> UInt8 { n == "linear" ? 1 : 0 }
        func mip(_ n: String?) -> UInt8 { n == "linear" ? 2 : (n == "nearest" ? 1 : 0) }
        func compare(_ n: String?) -> UInt8 {
            ["never": 0, "less": 1, "equal": 2, "less_equal": 3, "greater": 4, "not_equal": 5, "greater_equal": 6,
             "always": 7][n ?? "never"] ?? 0
        }
        func border(_ n: String?) -> UInt8 { n == "opaque_white" ? 2 : (n == "opaque_black" ? 1 : 0) }
        var d = MetalSamplerDescriptor()
        d.minFilter = filter(c.minFilter); d.magFilter = filter(c.magFilter); d.mipFilter = mip(c.mipFilter)
        d.sAddressMode = address(c.sAddress); d.tAddressMode = address(c.tAddress); d.rAddressMode = address(c.rAddress)
        d.borderColor = border(c.borderColor); d.compareFunction = compare(c.compareFunction)
        d.maxAnisotropy = UInt8(clamping: c.maxAnisotropy ?? 1); d.normalizedCoordinates = c.normalizedCoordinates ?? true
        d.lodMinClamp = Float(c.lodMin ?? 0); d.lodMaxClamp = Float(c.lodMax ?? Double(Float.greatestFiniteMagnitude))
        self.init(d)
    }
}

final class VKFunction: @unchecked Sendable {
    let metallib: [UInt8]
    init(metallib: [UInt8]) { self.metallib = metallib }
}

/// A render pipeline: translated stages plus one Vulkan pipeline per
/// topology class (point, line, triangle), built on first use.
/// Argument-table entries a translated function needs on every use: its
/// constant data and its constexpr samplers (ycode-airc's abi.h).
struct StageStatics {
    var entries: [(Int, UInt64)] = []
    var memory: [VKAllocation] = []
}

/// A render pipeline: translated stages plus one Vulkan pipeline per
/// topology class (point, line, triangle). Built asynchronously: `ready`
/// is left once translation and the first compile are done (or failed).
final class VKRenderPipeline: @unchecked Sendable {
    let desc: MetalRenderPipelineDescriptor
    let ready = DispatchGroup()
    var vertex: TranslatedShader?
    var fragment: TranslatedShader?
    var info = yvk_graphics_info()
    var vertexStatics = StageStatics()
    var fragmentStatics = StageStatics()
    /// Metal buffer indices bound as Vulkan vertex buffers.
    var vertexBufferIndices: [Int] = []
    var variants: [UInt32: VkPipeline] = [:]
    var failed: Set<UInt32> = []
    var depthFormat = VK_FORMAT_UNDEFINED
    var stencilFormat = VK_FORMAT_UNDEFINED
    /// Translation or setup failed: draws with it are skipped.
    var broken = false
    /// The guest released it (a late build destroys what it made).
    var released = false

    init(desc: MetalRenderPipelineDescriptor) { self.desc = desc }
    var isBuilt: Bool { vertex != nil && !broken }
}

/// A compute pipeline: one Vulkan pipeline per threadgroup size and
/// threadgroup-memory configuration. Translated asynchronously (`ready`).
final class VKComputePipeline: @unchecked Sendable {
    let ready = DispatchGroup()
    var shader: TranslatedShader?
    var statics = StageStatics()
    var variants: [ComputeVariantKey: VkPipeline] = [:]
    var failed: Set<ComputeVariantKey> = []
    var broken = false
    var released = false
    init() {}
}

struct ComputeVariantKey: Hashable {
    var x: Int, y: Int, z: Int
    var threadgroupMemory: [Int]
}

/// A Metal event or shared event: a timeline semaphore.
final class VKEvent {
    let semaphore: VkSemaphore?
    /// The largest value signaled or scheduled for signaling (timeline values must grow).
    var highest: UInt64 = 0
    init(semaphore: VkSemaphore?) { self.semaphore = semaphore }
}

/// Free-list index allocator for heap slots. Index 0 is reserved (dummy).
struct IndexAllocator {
    let capacity: UInt32
    private var next: UInt32 = 1
    private var free: [UInt32] = []

    init(capacity: UInt32) { self.capacity = capacity }

    mutating func allocate() -> UInt32? {
        if let i = free.popLast() { return i }
        guard next < capacity else { return nil }
        defer { next += 1 }
        return next
    }

    mutating func release(_ i: UInt32) {
        if i != 0 { free.append(i) }
    }
}

/// A chunk of host-visible memory for argument tables and staging data.
final class TransientChunk {
    var buffer: yvk_buffer
    var used = 0
    init(buffer: yvk_buffer) { self.buffer = buffer }
    var capacity: Int { Int(buffer.size) }
}

/// A slice of transient memory.
struct TransientSlice {
    let chunk: TransientChunk
    let offset: Int
    let length: Int
    var vkBuffer: VkBuffer? { chunk.buffer.buffer }
    var address: UInt64 { chunk.buffer.address + UInt64(offset) }
    var pointer: UnsafeMutableRawPointer { chunk.buffer.mapped! + offset }
}

/// One Vulkan command buffer being recorded, with what it uses.
final class Recording {
    let cb: VkCommandBuffer?
    var chunks: [TransientChunk] = []
    var current: TransientChunk?
    /// Images to download to their IOSurface at the end.
    var surfaceWrites: [ObjectIdentifier: VKImage] = [:]
    var heapBoundGraphics = false
    var heapBoundCompute = false
    var empty = true
    /// A semaphore wait this command buffer's submission must carry (event waits).
    var waitSemaphore: VkSemaphore?
    var waitValue: UInt64 = 0
    /// The shaders this recording uses (diagnostics: a GPU hang names them).
    var shaders: [String] = []
    /// The first dispatches' geometry and small buffer contents (diagnostics:
    /// a GPU hang prints them with the shaders).
    var dispatchNotes: [String] = []

    /// IOSurfaces this recording copies back to (their writes are pending
    /// until its serial completes).
    var writtenSurfaces: [UInt32] = []
    /// The same surfaces' planes (copy-in tracking).
    var writtenSurfaceKeys: [SurfaceSyncKey] = []
    /// Recorded now but submitted later (held behind an event wait): its
    /// copy-outs reach the surfaces only at submission.
    var deferred = false

    /// Draw statistics (diagnostics): draws, the largest vertex×instance
    /// count of one draw, indirect draws.
    var draws = 0, largestDraw = 0, indirectDraws = 0

    func noteDraw(_ work: Int) {
        draws += 1
        largestDraw = max(largestDraw, work)
    }

    func noteShaders(_ names: String) {
        if shaders.count < 16 && !shaders.contains(names) { shaders.append(names) }
    }

    /// Names its checkpoint markers (VulkanHangReport.swift).
    var checkpointID: UInt32 = 0

    init(cb: VkCommandBuffer?) { self.cb = cb }
}
