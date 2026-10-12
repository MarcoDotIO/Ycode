// Object descriptors of the Metal host protocol (metal-sim-protocol.md
// §5, §7) as backend-neutral values. Enum-valued fields keep the public
// Metal API's raw values (MTLPixelFormat, MTLTextureType, …; level 1).

import Foundation

/// `MTLStorageMode` (`MTLResourceOptions` bits 4–7).
public enum MetalStorageMode: UInt8, Sendable {
    case shared = 0
    case managed = 1
    case `private` = 2
    case memoryless = 3

    /// From `MTLResourceOptions`; unknown modes read as private.
    public init(resourceOptions: UInt64) {
        self = MetalStorageMode(rawValue: UInt8((resourceOptions >> 4) & 0xF)) ?? .private
    }
}

/// A region of a texture: origin and size in texels.
public struct MetalRegion: Equatable, Sendable, CustomStringConvertible {
    public var x: Int, y: Int, z: Int
    public var width: Int, height: Int, depth: Int
    public init(x: Int = 0, y: Int = 0, z: Int = 0, width: Int, height: Int, depth: Int = 1) {
        self.x = x; self.y = y; self.z = z
        self.width = width; self.height = height; self.depth = depth
    }
    public var description: String { "(\(x),\(y),\(z) \(width)x\(height)x\(depth))" }
}

/// `MTLPixelFormat` raw values and what the service needs to know of them.
public enum MetalPixelFormat {
    public static let invalid: UInt32 = 0
    public static let a8Unorm: UInt32 = 1
    public static let r8Unorm: UInt32 = 10
    public static let r8UnormSRGB: UInt32 = 11
    public static let r16Float: UInt32 = 25
    public static let rg8Unorm: UInt32 = 30
    public static let r32Float: UInt32 = 55
    public static let rg16Float: UInt32 = 65
    public static let rgba8Unorm: UInt32 = 70
    public static let rgba8UnormSRGB: UInt32 = 71
    public static let bgra8Unorm: UInt32 = 80
    public static let bgra8UnormSRGB: UInt32 = 81
    public static let rgb10a2Unorm: UInt32 = 90
    public static let rg11b10Float: UInt32 = 92
    public static let bgr10a2Unorm: UInt32 = 94
    public static let rgba16Unorm: UInt32 = 110
    public static let rgba16Float: UInt32 = 115
    public static let rgba32Float: UInt32 = 125
    public static let depth16Unorm: UInt32 = 250
    public static let depth32Float: UInt32 = 252
    public static let stencil8: UInt32 = 253
    public static let depth24UnormStencil8: UInt32 = 255
    public static let depth32FloatStencil8: UInt32 = 260
    public static let bgra10XR: UInt32 = 552
    public static let bgra10XRSRGB: UInt32 = 553
    public static let bgr10XR: UInt32 = 554
    public static let bgr10XRSRGB: UInt32 = 555

    /// Bytes per texel of an uncompressed format, nil when unknown or block-compressed.
    public static func bytesPerPixel(_ format: UInt32) -> Int? {
        switch format {
        case 1, 10, 11, 12, 13, 14, 253: return 1
        case 20, 22, 23, 24, 25, 30, 31, 32, 33, 34, 40, 41, 42, 43, 250: return 2
        case 53, 54, 55, 60, 62, 63, 64, 65, 70, 71, 72, 73, 74, 80, 81, 90, 91, 92, 93, 94, 252, 255, 554, 555: return 4
        case 103, 104, 105, 110, 112, 113, 114, 115, 260, 552, 553: return 8
        case 123, 124, 125: return 16
        default: return nil
        }
    }
}

/// `MTLTextureType` raw values.
public enum MetalTextureType {
    public static let type1D: UInt8 = 0
    public static let type1DArray: UInt8 = 1
    public static let type2D: UInt8 = 2
    public static let type2DArray: UInt8 = 3
    public static let type2DMultisample: UInt8 = 4
    public static let typeCube: UInt8 = 5
    public static let typeCubeArray: UInt8 = 6
    public static let type3D: UInt8 = 7
    public static let type2DMultisampleArray: UInt8 = 8
    public static let typeTextureBuffer: UInt8 = 9
}

/// `MTLTextureUsage` bits.
public enum MetalTextureUsage {
    public static let shaderRead: UInt16 = 0x1
    public static let shaderWrite: UInt16 = 0x2
    public static let renderTarget: UInt16 = 0x4
    public static let pixelFormatView: UInt16 = 0x10
}

/// A texture descriptor (spec §5.2: 36 bytes, nine words).
public struct MetalTextureDescriptor: Equatable, Sendable {
    public var textureType: UInt8
    public var pixelFormat: UInt32
    public var width: Int, height: Int, depth: Int
    public var mipmapLevelCount: Int
    public var sampleCount: Int
    public var arrayLength: Int
    /// `MTLTextureUsage` (low 8 bits travel).
    public var usage: UInt16
    /// `MTLResourceOptions` (16 bits): cache mode, storage mode, hazard tracking.
    public var resourceOptions: UInt16
    public var allowGPUOptimizedContents: Bool
    /// Word 1 bits 4 and 5 (seen on some IOSurface textures; meaning open).
    public var flags: UInt8
    /// Words 7–8 (open; always 0 in captures).
    public var reserved: UInt64

    public var storageMode: MetalStorageMode { MetalStorageMode(resourceOptions: UInt64(resourceOptions)) }

    public init(textureType: UInt8 = MetalTextureType.type2D, pixelFormat: UInt32, width: Int, height: Int = 1,
                depth: Int = 1, mipmapLevelCount: Int = 1, sampleCount: Int = 1, arrayLength: Int = 1,
                usage: UInt16 = MetalTextureUsage.shaderRead, resourceOptions: UInt16 = 0,
                allowGPUOptimizedContents: Bool = true, flags: UInt8 = 0, reserved: UInt64 = 0) {
        self.textureType = textureType
        self.pixelFormat = pixelFormat
        self.width = width; self.height = height; self.depth = depth
        self.mipmapLevelCount = mipmapLevelCount
        self.sampleCount = sampleCount
        self.arrayLength = arrayLength
        self.usage = usage
        self.resourceOptions = resourceOptions
        self.allowGPUOptimizedContents = allowGPUOptimizedContents
        self.flags = flags
        self.reserved = reserved
    }
}

/// A texture view (device ops 7, 8, 27). Nil fields keep the parent's value.
public struct MetalTextureViewDescriptor: Equatable, Sendable {
    public var pixelFormat: UInt32
    public var textureType: UInt8?
    public var levels: Range<Int>?
    public var slices: Range<Int>?
    /// One `MTLTextureSwizzle` byte per channel r, g, b, a (op 27); nil = identity.
    public var swizzle: [UInt8]?

    public init(pixelFormat: UInt32, textureType: UInt8? = nil, levels: Range<Int>? = nil, slices: Range<Int>? = nil,
                swizzle: [UInt8]? = nil) {
        self.pixelFormat = pixelFormat
        self.textureType = textureType
        self.levels = levels
        self.slices = slices
        self.swizzle = swizzle
    }
}

/// A sampler (spec §5.5). Values are the `MTLSampler*` raw values.
public struct MetalSamplerDescriptor: Equatable, Sendable {
    public var minFilter: UInt8 = 0
    public var magFilter: UInt8 = 0
    public var mipFilter: UInt8 = 0
    public var sAddressMode: UInt8 = 0
    public var tAddressMode: UInt8 = 0
    public var rAddressMode: UInt8 = 0
    public var borderColor: UInt8 = 0
    public var compareFunction: UInt8 = 0
    public var maxAnisotropy: UInt8 = 1
    public var normalizedCoordinates = true
    public var lodMinClamp: Float = 0
    public var lodMaxClamp: Float = .greatestFiniteMagnitude
    public var supportArgumentBuffers = false
    /// Packed-word bit 4 (open).
    public var bit4 = false

    public init() {}
}

/// One face's stencil state (spec §5.6). Values are `MTLCompareFunction`
/// and `MTLStencilOperation` raw values.
public struct MetalStencilDescriptor: Equatable, Sendable {
    public var compareFunction: UInt8
    public var stencilFailureOperation: UInt8
    public var depthFailureOperation: UInt8
    public var depthStencilPassOperation: UInt8
    public var readMask: UInt32
    public var writeMask: UInt32
    public init(compareFunction: UInt8 = 7, stencilFailureOperation: UInt8 = 0, depthFailureOperation: UInt8 = 0,
                depthStencilPassOperation: UInt8 = 0, readMask: UInt32 = 0xFFFF_FFFF, writeMask: UInt32 = 0xFFFF_FFFF) {
        self.compareFunction = compareFunction
        self.stencilFailureOperation = stencilFailureOperation
        self.depthFailureOperation = depthFailureOperation
        self.depthStencilPassOperation = depthStencilPassOperation
        self.readMask = readMask
        self.writeMask = writeMask
    }
}

/// A depth-stencil state (spec §5.6).
public struct MetalDepthStencilDescriptor: Equatable, Sendable {
    /// `MTLCompareFunction` (default 7 Always).
    public var depthCompareFunction: UInt8 = 7
    public var depthWriteEnabled = false
    public var frontFaceStencil: MetalStencilDescriptor?
    public var backFaceStencil: MetalStencilDescriptor?
    public init() {}
}

/// A render pipeline's color attachment (spec §7.2). Defaults are the
/// Metal API's (fields that travel only when different from them).
public struct MetalColorAttachmentDescriptor: Equatable, Sendable {
    public var index: Int
    public var pixelFormat: UInt32 = 0
    public var blendingEnabled = false
    /// `MTLBlendFactor`: 0 Zero, 1 One, … ; `MTLBlendOperation`: 0 Add, …
    public var sourceRGBBlendFactor: UInt32 = 1
    public var destinationRGBBlendFactor: UInt32 = 0
    public var rgbBlendOperation: UInt32 = 0
    public var sourceAlphaBlendFactor: UInt32 = 1
    public var destinationAlphaBlendFactor: UInt32 = 0
    public var alphaBlendOperation: UInt32 = 0
    /// `MTLColorWriteMask` (default 0xF All).
    public var writeMask: UInt32 = 0xF
    public init(index: Int) { self.index = index }
}

/// A vertex descriptor (spec §7.2).
public struct MetalVertexDescriptor: Equatable, Sendable {
    public struct Attribute: Equatable, Sendable {
        public var index: Int
        /// `MTLVertexFormat`.
        public var format: UInt32 = 0
        public var offset: Int = 0
        public var bufferIndex: Int = 0
        public init(index: Int) { self.index = index }
    }
    public struct Layout: Equatable, Sendable {
        public var bufferIndex: Int
        /// `MTLVertexStepFunction` (default 1 PerVertex).
        public var stepFunction: UInt32 = 1
        public var stepRate: Int = 1
        public var stride: Int = 0
        public init(bufferIndex: Int) { self.bufferIndex = bufferIndex }
    }
    public var attributes: [Attribute] = []
    /// As sent: may repeat a buffer index (one element per attribute).
    public var layouts: [Layout] = []
    public init() {}
}

/// A render pipeline (op 14, spec §7.2). Function fields are handles.
public struct MetalRenderPipelineDescriptor: Equatable, Sendable {
    public var label: String?
    public var vertexFunction: MetalHandle?
    public var fragmentFunction: MetalHandle?
    public var vertexDescriptor: MetalVertexDescriptor?
    public var rasterSampleCount: Int = 1
    public var alphaToCoverageEnabled = false
    public var colorAttachments: [MetalColorAttachmentDescriptor] = []
    public var depthAttachmentPixelFormat: UInt32 = 0
    public var stencilAttachmentPixelFormat: UInt32 = 0
    /// `MTLPrimitiveTopologyClass` (0 Unspecified).
    public var inputPrimitiveTopology: UInt32 = 0
    /// Top-level keys the decoder does not know (key → value as sent).
    public var unknownKeys: [UInt8: UInt64] = [:]
    public init() {}
}

/// `MTLPrimitiveType`, `MTLIndexType`, `MTLLoadAction`, `MTLStoreAction`.
public enum MetalPrimitiveType {
    public static let point: UInt32 = 0
    public static let line: UInt32 = 1
    public static let lineStrip: UInt32 = 2
    public static let triangle: UInt32 = 3
    public static let triangleStrip: UInt32 = 4
}

public enum MetalIndexType {
    public static let uint16: UInt32 = 0
    public static let uint32: UInt32 = 1
}

public enum MetalLoadAction {
    public static let dontCare: UInt16 = 0
    public static let load: UInt16 = 1
    public static let clear: UInt16 = 2
}

public enum MetalStoreAction {
    public static let dontCare: UInt16 = 0
    public static let store: UInt16 = 1
    public static let multisampleResolve: UInt16 = 2
}
