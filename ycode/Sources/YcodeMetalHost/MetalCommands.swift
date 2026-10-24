// The backend-neutral command model: a submitted command buffer (spec §8)
// decoded into passes of commands, with every guest ref replaced by a
// handle (nil = the guest's nil). Bindings are state, as in Metal: a set
// command changes one slot until the end of its pass; process commands in
// order (the driver's inline bytes rely on that, spec §5.1).

import Foundation

/// The stage a render binding applies to.
public enum MetalRenderStage: UInt8, Sendable {
    case vertex
    case fragment
}

/// One submitted command buffer.
public struct MetalCommandBuffer: Sendable {
    public var process: MetalProcessID
    /// The queue (command buffers of one queue run in submission order).
    public var queue: MetalHandle?
    /// The guest's command-buffer ref (reused once completed; not unique).
    public var commandBufferRef: UInt64
    public var passes: [MetalPass]
    /// Records the decoder did not know (also present as `.unknown` commands).
    public var unknownRecordCount: Int
    /// Problems found while decoding (malformed segments, unknown refs).
    public var diagnostics: [String]
    /// When the host service received the submission (monotonic ns; 0 =
    /// unknown). Diagnostics only (the back end's frame trace).
    public var receivedAtNs: UInt64 = 0

    public init(process: MetalProcessID, queue: MetalHandle?, commandBufferRef: UInt64, passes: [MetalPass] = [],
                unknownRecordCount: Int = 0, diagnostics: [String] = []) {
        self.process = process
        self.queue = queue
        self.commandBufferRef = commandBufferRef
        self.passes = passes
        self.unknownRecordCount = unknownRecordCount
        self.diagnostics = diagnostics
    }

    /// Every texture a render pass of this command buffer writes as an
    /// attachment (color, depth, stencil, resolve).
    public var renderTargets: Set<MetalHandle> {
        var out: Set<MetalHandle> = []
        for case let .render(p) in passes {
            guard let d = p.descriptor else { continue }
            for a in d.colorAttachments { if let t = a.texture { out.insert(t) }; if let r = a.resolveTexture { out.insert(r) } }
            for a in [d.depth, d.stencil].compactMap({ $0 }) {
                if let t = a.texture { out.insert(t) }
                if let r = a.resolveTexture { out.insert(r) }
            }
        }
        return out
    }
}

/// One encoder's work.
public enum MetalPass: Sendable {
    case render(MetalRenderPass)
    case compute([MetalComputeCommand])
    case blit([MetalBlitCommand])
    /// Event encoder records between encoders (spec §8.4, kind 3).
    case event([MetalEventCommand])
    /// A segment of an encoder kind the decoder does not know.
    case unknown(kind: UInt8, records: [MetalUnknownRecord])
}

public struct MetalUnknownRecord: Equatable, Sendable {
    public var op: UInt32
    public var body: [UInt8]
    public init(op: UInt32, body: [UInt8]) { self.op = op; self.body = body }
}

// MARK: Render

/// An attachment of a render pass (spec §8.6).
public struct MetalRenderPassAttachment: Equatable, Sendable {
    public var texture: MetalHandle?
    public var resolveTexture: MetalHandle?
    public var level: Int
    public var slice: Int
    /// `MTLLoadAction` / `MTLStoreAction`.
    public var loadAction: UInt16
    public var storeAction: UInt16
    /// The words marked open in the spec (+12, +16, +24), as sent.
    public var openWords: [UInt32]

    public init(texture: MetalHandle?, resolveTexture: MetalHandle? = nil, level: Int = 0, slice: Int = 0,
                loadAction: UInt16, storeAction: UInt16, openWords: [UInt32] = [0, 0, 0]) {
        self.texture = texture
        self.resolveTexture = resolveTexture
        self.level = level
        self.slice = slice
        self.loadAction = loadAction
        self.storeAction = storeAction
        self.openWords = openWords
    }
}

public struct MetalColorAttachment: Equatable, Sendable {
    /// The attachment index (0…7).
    public var index: Int
    public var attachment: MetalRenderPassAttachment
    /// r, g, b, a.
    public var clearColor: [Double]

    public init(index: Int, attachment: MetalRenderPassAttachment, clearColor: [Double] = [0, 0, 0, 1]) {
        self.index = index
        self.attachment = attachment
        self.clearColor = clearColor
    }

    public var texture: MetalHandle? { attachment.texture }
    public var resolveTexture: MetalHandle? { attachment.resolveTexture }
}

/// A render pass descriptor (record 26). Only color attachments with a
/// texture are listed; depth and stencil are nil without a texture.
public struct MetalRenderPassDescriptor: Equatable, Sendable {
    public var colorAttachments: [MetalColorAttachment] = []
    public var depth: MetalRenderPassAttachment?
    public var clearDepth: Double = 1
    public var stencil: MetalRenderPassAttachment?
    public var clearStencil: UInt32 = 0
    public var visibilityResultBuffer: MetalHandle?
    public var renderTargetWidth: Int = 0
    public var renderTargetHeight: Int = 0
    public init() {}

    public init(colorAttachments: [MetalColorAttachment], depth: MetalRenderPassAttachment? = nil, clearDepth: Double = 1,
                stencil: MetalRenderPassAttachment? = nil, clearStencil: UInt32 = 0,
                visibilityResultBuffer: MetalHandle? = nil, renderTargetWidth: Int = 0, renderTargetHeight: Int = 0) {
        self.colorAttachments = colorAttachments
        self.depth = depth
        self.clearDepth = clearDepth
        self.stencil = stencil
        self.clearStencil = clearStencil
        self.visibilityResultBuffer = visibilityResultBuffer
        self.renderTargetWidth = renderTargetWidth
        self.renderTargetHeight = renderTargetHeight
    }

    /// Width and height from the first attachment when the descriptor gives none.
    public var hasAttachments: Bool { !colorAttachments.isEmpty || depth != nil || stencil != nil }
}

public struct MetalRenderPass: Sendable {
    /// Nil when the encoder's first record was not a begin-pass record (26).
    public var descriptor: MetalRenderPassDescriptor?
    public var commands: [MetalRenderCommand]
    public init(descriptor: MetalRenderPassDescriptor?, commands: [MetalRenderCommand] = []) {
        self.descriptor = descriptor
        self.commands = commands
    }
}

public struct MetalViewport: Equatable, Sendable {
    public var x: Double, y: Double, width: Double, height: Double, znear: Double, zfar: Double
    public init(x: Double, y: Double, width: Double, height: Double, znear: Double, zfar: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height; self.znear = znear; self.zfar = zfar
    }
}

public struct MetalScissorRect: Equatable, Sendable {
    public var x: Int, y: Int, width: Int, height: Int
    public init(x: Int, y: Int, width: Int, height: Int) { self.x = x; self.y = y; self.width = width; self.height = height }
}

/// A non-indexed draw (records 0, 1, 3, 5).
public struct MetalDraw: Equatable, Sendable {
    public var primitiveType: UInt32
    public var vertexStart: Int
    public var vertexCount: Int
    public var instanceCount: Int = 1
    public var baseInstance: Int = 0
    public init(primitiveType: UInt32, vertexStart: Int, vertexCount: Int, instanceCount: Int = 1, baseInstance: Int = 0) {
        self.primitiveType = primitiveType
        self.vertexStart = vertexStart
        self.vertexCount = vertexCount
        self.instanceCount = instanceCount
        self.baseInstance = baseInstance
    }
}

/// An indexed draw (records 6, 7, 9, 29).
public struct MetalIndexedDraw: Equatable, Sendable {
    public var primitiveType: UInt32
    /// `MTLIndexType`: 0 UInt16, 1 UInt32.
    public var indexType: UInt32
    public var indexBuffer: MetalHandle?
    public var indexBufferOffset: Int
    public var indexCount: Int
    public var instanceCount: Int = 1
    public var baseVertex: Int = 0
    public var baseInstance: Int = 0
    public init(primitiveType: UInt32, indexType: UInt32, indexBuffer: MetalHandle?, indexBufferOffset: Int, indexCount: Int,
                instanceCount: Int = 1, baseVertex: Int = 0, baseInstance: Int = 0) {
        self.primitiveType = primitiveType
        self.indexType = indexType
        self.indexBuffer = indexBuffer
        self.indexBufferOffset = indexBufferOffset
        self.indexCount = indexCount
        self.instanceCount = instanceCount
        self.baseVertex = baseVertex
        self.baseInstance = baseInstance
    }
}

public enum MetalRenderCommand: Equatable, Sendable {
    case setRenderPipelineState(MetalHandle?)
    case setDepthStencilState(MetalHandle?)
    case setBuffer(stage: MetalRenderStage, index: Int, buffer: MetalHandle?, offset: Int)
    case setBufferOffset(stage: MetalRenderStage, index: Int, offset: Int)
    case setTexture(stage: MetalRenderStage, index: Int, texture: MetalHandle?)
    /// `lodClamp` nil: the sampler's own clamps.
    case setSamplerState(stage: MetalRenderStage, index: Int, sampler: MetalHandle?, lodMinClamp: Float?, lodMaxClamp: Float?)
    case setViewport(MetalViewport)
    case setScissorRect(MetalScissorRect)
    /// `MTLCullMode`, `MTLWinding`, `MTLTriangleFillMode`, `MTLDepthClipMode`.
    case setCullMode(UInt64)
    case setFrontFacingWinding(UInt64)
    case setTriangleFillMode(UInt64)
    case setDepthClipMode(UInt64)
    case setDepthBias(depthBias: Float, slopeScale: Float, clamp: Float)
    case setBlendColor(red: Float, green: Float, blue: Float, alpha: Float)
    case setStencilReference(front: UInt32, back: UInt32)
    /// Record 102: two words, order open (both 0 in captures).
    case setColorStoreAction(first: UInt32, second: UInt32)
    case draw(MetalDraw)
    case drawIndexed(MetalIndexedDraw)
    case drawIndirect(primitiveType: UInt32, indirectBuffer: MetalHandle?, indirectOffset: Int)
    case drawIndexedIndirect(primitiveType: UInt32, indexType: UInt32, indexBuffer: MetalHandle?, indexBufferOffset: Int,
                             indirectBuffer: MetalHandle?, indirectOffset: Int)
    /// `memoryBarrierWithScope:afterStages:beforeStages:`.
    case memoryBarrier(scope: UInt16, afterStages: UInt8, beforeStages: UInt8)
    /// Records 135/137 (`stages` nil for 135).
    case useResources([MetalHandle], usage: UInt32, stages: UInt16?)
    case unknown(op: UInt32, body: [UInt8])
}

// MARK: Compute

public struct MetalSize3: Equatable, Sendable {
    public var width: Int, height: Int, depth: Int
    public init(_ width: Int, _ height: Int, _ depth: Int) { self.width = width; self.height = height; self.depth = depth }
}

public enum MetalComputeCommand: Equatable, Sendable {
    case setComputePipelineState(MetalHandle?)
    case setBuffer(index: Int, buffer: MetalHandle?, offset: Int)
    case setBufferOffset(index: Int, offset: Int)
    case setTexture(index: Int, texture: MetalHandle?)
    case setSamplerState(index: Int, sampler: MetalHandle?, lodMinClamp: Float?, lodMaxClamp: Float?)
    case setThreadgroupMemoryLength(Int, index: Int)
    case setStageInRegion(origin: MetalSize3, size: MetalSize3)
    case dispatchThreadgroups(MetalSize3, threadsPerThreadgroup: MetalSize3)
    case dispatchThreads(MetalSize3, threadsPerThreadgroup: MetalSize3)
    case dispatchThreadgroupsIndirect(buffer: MetalHandle?, offset: Int, threadsPerThreadgroup: MetalSize3)
    case memoryBarrier(scope: UInt32)
    case memoryBarrierResources([MetalHandle])
    case useResources([MetalHandle], usage: UInt32, stages: UInt16?)
    case unknown(op: UInt32, body: [UInt8])
}

// MARK: Blit

public enum MetalBlitCommand: Equatable, Sendable {
    case copyBufferToTexture(source: MetalHandle?, sourceOffset: Int, bytesPerRow: Int, bytesPerImage: Int, size: MetalSize3,
                             destination: MetalHandle?, slice: Int, level: Int, origin: MetalSize3, options: UInt32)
    case copyBufferToBuffer(source: MetalHandle?, sourceOffset: Int, destination: MetalHandle?, destinationOffset: Int, size: Int)
    case copyTextureToBuffer(source: MetalHandle?, slice: Int, level: Int, origin: MetalSize3, size: MetalSize3,
                             destination: MetalHandle?, destinationOffset: Int, bytesPerRow: Int, bytesPerImage: Int,
                             options: UInt32)
    case copyTextureToTexture(source: MetalHandle?, sourceSlice: Int, sourceLevel: Int, sourceOrigin: MetalSize3, size: MetalSize3,
                              destination: MetalHandle?, destinationSlice: Int, destinationLevel: Int, destinationOrigin: MetalSize3)
    /// Record 318: whole slices and levels.
    case copyTextureSlices(source: MetalHandle?, sourceSlice: Int, sourceLevel: Int, destination: MetalHandle?,
                           destinationSlice: Int, destinationLevel: Int, sliceCount: Int, levelCount: Int)
    case fillBuffer(MetalHandle?, location: Int, length: Int, value: UInt32)
    case generateMipmaps(MetalHandle?)
    case optimizeContentsForGPUAccess(MetalHandle?)
    case updateFence(MetalHandle?)
    case waitForFence(MetalHandle?)
    case unknown(op: UInt32, body: [UInt8])
}

// MARK: Event

public enum MetalEventCommand: Equatable, Sendable {
    /// Hold the rest of the command buffer until the event reaches `value`
    /// (also by a later CPU signal, `MetalBackend.signalEvent`).
    case wait(MetalHandle?, value: UInt64)
    case signal(MetalHandle?, value: UInt64)
    case unknown(op: UInt32, body: [UInt8])
}
