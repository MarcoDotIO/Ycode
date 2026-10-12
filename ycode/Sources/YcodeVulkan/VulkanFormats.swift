// Metal → Vulkan value mappings: pixel formats, vertex formats, blend,
// compare and stencil functions, sampler fields. Metal raw values are the
// public MTL* enum values (level 1: the SDK's Metal headers); Vulkan values
// are from the Vulkan specification.

import CVulkan

/// How one Metal pixel format lives in Vulkan.
public struct VulkanPixelFormat: Equatable, Sendable {
    /// The Vulkan format of images created for it.
    public var format: VkFormat
    /// The aspects the image has (color, depth, stencil).
    public var aspect: VkImageAspectFlags
    /// The aspect a shader view samples (depth for depth/stencil formats, stencil for stencil-only views).
    public var viewAspect: VkImageAspectFlags
    /// Bytes per texel or per compressed block; block size in texels.
    public var bytesPerBlock: Int
    public var blockWidth: Int
    public var blockHeight: Int
    /// A component swizzle applied to every view (A8 on R8, for instance).
    public var swizzle: VkComponentMapping
    /// The format only approximates Metal's (documented in the coverage table).
    public var approximate: Bool

    public var isDepth: Bool { aspect & VK_IMAGE_ASPECT_DEPTH_BIT.rawValue != 0 }
    public var isStencil: Bool { aspect & VK_IMAGE_ASPECT_STENCIL_BIT.rawValue != 0 }
    public var isColor: Bool { aspect & VK_IMAGE_ASPECT_COLOR_BIT.rawValue != 0 }
    public var isCompressed: Bool { blockWidth > 1 || blockHeight > 1 }
}

let identitySwizzle = VkComponentMapping(r: VK_COMPONENT_SWIZZLE_IDENTITY, g: VK_COMPONENT_SWIZZLE_IDENTITY,
                                         b: VK_COMPONENT_SWIZZLE_IDENTITY, a: VK_COMPONENT_SWIZZLE_IDENTITY)

private let color = VK_IMAGE_ASPECT_COLOR_BIT.rawValue
private let depth = VK_IMAGE_ASPECT_DEPTH_BIT.rawValue
private let stencil = VK_IMAGE_ASPECT_STENCIL_BIT.rawValue

private func plain(_ f: VkFormat, _ bpp: Int) -> VulkanPixelFormat {
    VulkanPixelFormat(format: f, aspect: color, viewAspect: color, bytesPerBlock: bpp, blockWidth: 1, blockHeight: 1,
                      swizzle: identitySwizzle, approximate: false)
}

private func block(_ f: VkFormat, _ bytes: Int, _ w: Int, _ h: Int) -> VulkanPixelFormat {
    VulkanPixelFormat(format: f, aspect: color, viewAspect: color, bytesPerBlock: bytes, blockWidth: w, blockHeight: h,
                      swizzle: identitySwizzle, approximate: false)
}

private func ds(_ f: VkFormat, _ aspect: UInt32, _ viewAspect: UInt32, _ bpp: Int) -> VulkanPixelFormat {
    VulkanPixelFormat(format: f, aspect: aspect, viewAspect: viewAspect, bytesPerBlock: bpp, blockWidth: 1,
                      blockHeight: 1, swizzle: identitySwizzle, approximate: false)
}

/// ASTC block sizes in Metal's order (4x4 … 12x12) and the matching Vulkan
/// UNORM format of each (the SRGB format follows it).
private let astcBlocks: [(Int, Int)] = [(4, 4), (5, 4), (5, 5), (6, 5), (6, 6), (8, 5), (8, 6), (8, 8), (10, 5),
                                        (10, 6), (10, 8), (10, 10), (12, 10), (12, 12)]
private let astcLDR: [UInt32] = [204, 205, 206, 207, 208, 210, 211, 212, 213, 214, 215, 216, 217, 218]
private let astcSRGB: [UInt32] = [186, 187, 188, 189, 190, 192, 193, 194, 195, 196, 197, 198, 199, 200]

/// The static part of the pixel-format table (no device queries).
public func metalPixelFormatTable(_ metal: UInt32) -> VulkanPixelFormat? {
    switch metal {
    case 1: return plain(VK_FORMAT_A8_UNORM_KHR, 1)
    case 10: return plain(VK_FORMAT_R8_UNORM, 1)
    case 11: return plain(VK_FORMAT_R8_SRGB, 1)
    case 12: return plain(VK_FORMAT_R8_SNORM, 1)
    case 13: return plain(VK_FORMAT_R8_UINT, 1)
    case 14: return plain(VK_FORMAT_R8_SINT, 1)
    case 20: return plain(VK_FORMAT_R16_UNORM, 2)
    case 22: return plain(VK_FORMAT_R16_SNORM, 2)
    case 23: return plain(VK_FORMAT_R16_UINT, 2)
    case 24: return plain(VK_FORMAT_R16_SINT, 2)
    case 25: return plain(VK_FORMAT_R16_SFLOAT, 2)
    case 30: return plain(VK_FORMAT_R8G8_UNORM, 2)
    case 31: return plain(VK_FORMAT_R8G8_SRGB, 2)
    case 32: return plain(VK_FORMAT_R8G8_SNORM, 2)
    case 33: return plain(VK_FORMAT_R8G8_UINT, 2)
    case 34: return plain(VK_FORMAT_R8G8_SINT, 2)
    // Packed 16-bit formats: Metal names components from the least
    // significant bits, Vulkan from the most significant.
    case 40: return plain(VK_FORMAT_R5G6B5_UNORM_PACK16, 2)
    case 41: return plain(VK_FORMAT_R5G5B5A1_UNORM_PACK16, 2)
    case 42: return plain(VK_FORMAT_R4G4B4A4_UNORM_PACK16, 2)
    case 43: return plain(VK_FORMAT_A1R5G5B5_UNORM_PACK16, 2)
    case 45: return plain(VK_FORMAT_R8G8B8_UNORM, 3)
    case 46: return plain(VK_FORMAT_R8G8B8_SNORM, 3)
    case 47: return plain(VK_FORMAT_R8G8B8_UINT, 3)
    case 48: return plain(VK_FORMAT_R8G8B8_SINT, 3)
    case 53: return plain(VK_FORMAT_R32_UINT, 4)
    case 54: return plain(VK_FORMAT_R32_SINT, 4)
    case 55: return plain(VK_FORMAT_R32_SFLOAT, 4)
    case 60: return plain(VK_FORMAT_R16G16_UNORM, 4)
    case 62: return plain(VK_FORMAT_R16G16_SNORM, 4)
    case 63: return plain(VK_FORMAT_R16G16_UINT, 4)
    case 64: return plain(VK_FORMAT_R16G16_SINT, 4)
    case 65: return plain(VK_FORMAT_R16G16_SFLOAT, 4)
    case 70: return plain(VK_FORMAT_R8G8B8A8_UNORM, 4)
    case 71: return plain(VK_FORMAT_R8G8B8A8_SRGB, 4)
    case 72: return plain(VK_FORMAT_R8G8B8A8_SNORM, 4)
    case 73: return plain(VK_FORMAT_R8G8B8A8_UINT, 4)
    case 74: return plain(VK_FORMAT_R8G8B8A8_SINT, 4)
    case 80: return plain(VK_FORMAT_B8G8R8A8_UNORM, 4)
    case 81: return plain(VK_FORMAT_B8G8R8A8_SRGB, 4)
    case 90: return plain(VK_FORMAT_A2B10G10R10_UNORM_PACK32, 4)
    case 91: return plain(VK_FORMAT_A2B10G10R10_UINT_PACK32, 4)
    case 92: return plain(VK_FORMAT_B10G11R11_UFLOAT_PACK32, 4)
    case 93: return plain(VK_FORMAT_E5B9G9R9_UFLOAT_PACK32, 4)
    case 94: return plain(VK_FORMAT_A2R10G10B10_UNORM_PACK32, 4)
    case 95: return plain(VK_FORMAT_R16G16B16_UNORM, 6)
    case 96: return plain(VK_FORMAT_R16G16B16_SNORM, 6)
    case 97: return plain(VK_FORMAT_R16G16B16_UINT, 6)
    case 98: return plain(VK_FORMAT_R16G16B16_SINT, 6)
    case 99: return plain(VK_FORMAT_R16G16B16_SFLOAT, 6)
    case 103: return plain(VK_FORMAT_R32G32_UINT, 8)
    case 104: return plain(VK_FORMAT_R32G32_SINT, 8)
    case 105: return plain(VK_FORMAT_R32G32_SFLOAT, 8)
    case 110: return plain(VK_FORMAT_R16G16B16A16_UNORM, 8)
    case 112: return plain(VK_FORMAT_R16G16B16A16_SNORM, 8)
    case 113: return plain(VK_FORMAT_R16G16B16A16_UINT, 8)
    case 114: return plain(VK_FORMAT_R16G16B16A16_SINT, 8)
    case 115: return plain(VK_FORMAT_R16G16B16A16_SFLOAT, 8)
    case 120: return plain(VK_FORMAT_R32G32B32_UINT, 12)
    case 121: return plain(VK_FORMAT_R32G32B32_SINT, 12)
    case 122: return plain(VK_FORMAT_R32G32B32_SFLOAT, 12)
    case 123: return plain(VK_FORMAT_R32G32B32A32_UINT, 16)
    case 124: return plain(VK_FORMAT_R32G32B32A32_SINT, 16)
    case 125: return plain(VK_FORMAT_R32G32B32A32_SFLOAT, 16)
    case 130: return block(VK_FORMAT_BC1_RGBA_UNORM_BLOCK, 8, 4, 4)
    case 131: return block(VK_FORMAT_BC1_RGBA_SRGB_BLOCK, 8, 4, 4)
    case 132: return block(VK_FORMAT_BC2_UNORM_BLOCK, 16, 4, 4)
    case 133: return block(VK_FORMAT_BC2_SRGB_BLOCK, 16, 4, 4)
    case 134: return block(VK_FORMAT_BC3_UNORM_BLOCK, 16, 4, 4)
    case 135: return block(VK_FORMAT_BC3_SRGB_BLOCK, 16, 4, 4)
    case 140: return block(VK_FORMAT_BC4_UNORM_BLOCK, 8, 4, 4)
    case 141: return block(VK_FORMAT_BC4_SNORM_BLOCK, 8, 4, 4)
    case 142: return block(VK_FORMAT_BC5_UNORM_BLOCK, 16, 4, 4)
    case 143: return block(VK_FORMAT_BC5_SNORM_BLOCK, 16, 4, 4)
    case 150: return block(VK_FORMAT_BC6H_SFLOAT_BLOCK, 16, 4, 4)
    case 151: return block(VK_FORMAT_BC6H_UFLOAT_BLOCK, 16, 4, 4)
    case 152: return block(VK_FORMAT_BC7_UNORM_BLOCK, 16, 4, 4)
    case 153: return block(VK_FORMAT_BC7_SRGB_BLOCK, 16, 4, 4)
    case 170: return block(VK_FORMAT_EAC_R11_UNORM_BLOCK, 8, 4, 4)
    case 172: return block(VK_FORMAT_EAC_R11_SNORM_BLOCK, 8, 4, 4)
    case 174: return block(VK_FORMAT_EAC_R11G11_UNORM_BLOCK, 16, 4, 4)
    case 176: return block(VK_FORMAT_EAC_R11G11_SNORM_BLOCK, 16, 4, 4)
    case 178: return block(VK_FORMAT_ETC2_R8G8B8A8_UNORM_BLOCK, 16, 4, 4)
    case 179: return block(VK_FORMAT_ETC2_R8G8B8A8_SRGB_BLOCK, 16, 4, 4)
    case 180: return block(VK_FORMAT_ETC2_R8G8B8_UNORM_BLOCK, 8, 4, 4)
    case 181: return block(VK_FORMAT_ETC2_R8G8B8_SRGB_BLOCK, 8, 4, 4)
    case 182: return block(VK_FORMAT_ETC2_R8G8B8A1_UNORM_BLOCK, 8, 4, 4)
    case 183: return block(VK_FORMAT_ETC2_R8G8B8A1_SRGB_BLOCK, 8, 4, 4)
    case 250: return ds(VK_FORMAT_D16_UNORM, depth, depth, 2)
    case 252: return ds(VK_FORMAT_D32_SFLOAT, depth, depth, 4)
    case 253: return ds(VK_FORMAT_S8_UINT, stencil, stencil, 1)
    case 255: return ds(VK_FORMAT_D24_UNORM_S8_UINT, depth | stencil, depth, 4)
    case 260: return ds(VK_FORMAT_D32_SFLOAT_S8_UINT, depth | stencil, depth, 5)
    case 261: return ds(VK_FORMAT_D32_SFLOAT_S8_UINT, depth | stencil, stencil, 5)
    case 262: return ds(VK_FORMAT_D24_UNORM_S8_UINT, depth | stencil, stencil, 4)
    default:
        if let i = astcLDR.firstIndex(of: metal) {
            return block(VkFormat(rawValue: VK_FORMAT_ASTC_4x4_UNORM_BLOCK.rawValue + UInt32(2 * i)), 16,
                         astcBlocks[i].0, astcBlocks[i].1)
        }
        if let i = astcSRGB.firstIndex(of: metal) {
            return block(VkFormat(rawValue: VK_FORMAT_ASTC_4x4_SRGB_BLOCK.rawValue + UInt32(2 * i)), 16,
                         astcBlocks[i].0, astcBlocks[i].1)
        }
        return nil
    }
}

/// `MTLVertexFormat` → Vulkan vertex attribute format.
public func metalVertexFormat(_ metal: UInt32) -> VkFormat? {
    switch metal {
    case 1: return VK_FORMAT_R8G8_UINT
    case 2: return VK_FORMAT_R8G8B8_UINT
    case 3: return VK_FORMAT_R8G8B8A8_UINT
    case 4: return VK_FORMAT_R8G8_SINT
    case 5: return VK_FORMAT_R8G8B8_SINT
    case 6: return VK_FORMAT_R8G8B8A8_SINT
    case 7: return VK_FORMAT_R8G8_UNORM
    case 8: return VK_FORMAT_R8G8B8_UNORM
    case 9: return VK_FORMAT_R8G8B8A8_UNORM
    case 10: return VK_FORMAT_R8G8_SNORM
    case 11: return VK_FORMAT_R8G8B8_SNORM
    case 12: return VK_FORMAT_R8G8B8A8_SNORM
    case 13: return VK_FORMAT_R16G16_UINT
    case 14: return VK_FORMAT_R16G16B16_UINT
    case 15: return VK_FORMAT_R16G16B16A16_UINT
    case 16: return VK_FORMAT_R16G16_SINT
    case 17: return VK_FORMAT_R16G16B16_SINT
    case 18: return VK_FORMAT_R16G16B16A16_SINT
    case 19: return VK_FORMAT_R16G16_UNORM
    case 20: return VK_FORMAT_R16G16B16_UNORM
    case 21: return VK_FORMAT_R16G16B16A16_UNORM
    case 22: return VK_FORMAT_R16G16_SNORM
    case 23: return VK_FORMAT_R16G16B16_SNORM
    case 24: return VK_FORMAT_R16G16B16A16_SNORM
    case 25: return VK_FORMAT_R16G16_SFLOAT
    case 26: return VK_FORMAT_R16G16B16_SFLOAT
    case 27: return VK_FORMAT_R16G16B16A16_SFLOAT
    case 28: return VK_FORMAT_R32_SFLOAT
    case 29: return VK_FORMAT_R32G32_SFLOAT
    case 30: return VK_FORMAT_R32G32B32_SFLOAT
    case 31: return VK_FORMAT_R32G32B32A32_SFLOAT
    case 32: return VK_FORMAT_R32_SINT
    case 33: return VK_FORMAT_R32G32_SINT
    case 34: return VK_FORMAT_R32G32B32_SINT
    case 35: return VK_FORMAT_R32G32B32A32_SINT
    case 36: return VK_FORMAT_R32_UINT
    case 37: return VK_FORMAT_R32G32_UINT
    case 38: return VK_FORMAT_R32G32B32_UINT
    case 39: return VK_FORMAT_R32G32B32A32_UINT
    case 40: return VK_FORMAT_A2B10G10R10_SNORM_PACK32
    case 41: return VK_FORMAT_A2B10G10R10_UNORM_PACK32
    case 42: return VK_FORMAT_B8G8R8A8_UNORM
    case 45: return VK_FORMAT_R8_UINT
    case 46: return VK_FORMAT_R8_SINT
    case 47: return VK_FORMAT_R8_UNORM
    case 48: return VK_FORMAT_R8_SNORM
    case 49: return VK_FORMAT_R16_UINT
    case 50: return VK_FORMAT_R16_SINT
    case 51: return VK_FORMAT_R16_UNORM
    case 52: return VK_FORMAT_R16_SNORM
    case 53: return VK_FORMAT_R16_SFLOAT
    case 54: return VK_FORMAT_B10G11R11_UFLOAT_PACK32
    case 55: return VK_FORMAT_E5B9G9R9_UFLOAT_PACK32
    default: return nil
    }
}

/// `MTLCompareFunction` → `VkCompareOp` (same order: Never, Less, Equal,
/// LessEqual, Greater, NotEqual, GreaterEqual, Always).
func vkCompare(_ metal: UInt8) -> VkCompareOp {
    switch metal {
    case 0: return VK_COMPARE_OP_NEVER
    case 1: return VK_COMPARE_OP_LESS
    case 2: return VK_COMPARE_OP_EQUAL
    case 3: return VK_COMPARE_OP_LESS_OR_EQUAL
    case 4: return VK_COMPARE_OP_GREATER
    case 5: return VK_COMPARE_OP_NOT_EQUAL
    case 6: return VK_COMPARE_OP_GREATER_OR_EQUAL
    default: return VK_COMPARE_OP_ALWAYS
    }
}

/// `MTLStencilOperation` → `VkStencilOp`.
func vkStencilOp(_ metal: UInt8) -> VkStencilOp {
    switch metal {
    case 1: return VK_STENCIL_OP_ZERO
    case 2: return VK_STENCIL_OP_REPLACE
    case 3: return VK_STENCIL_OP_INCREMENT_AND_CLAMP
    case 4: return VK_STENCIL_OP_DECREMENT_AND_CLAMP
    case 5: return VK_STENCIL_OP_INVERT
    case 6: return VK_STENCIL_OP_INCREMENT_AND_WRAP
    case 7: return VK_STENCIL_OP_DECREMENT_AND_WRAP
    default: return VK_STENCIL_OP_KEEP
    }
}

/// `MTLBlendFactor` → `VkBlendFactor`.
func vkBlendFactor(_ metal: UInt32) -> VkBlendFactor {
    switch metal {
    case 0: return VK_BLEND_FACTOR_ZERO
    case 1: return VK_BLEND_FACTOR_ONE
    case 2: return VK_BLEND_FACTOR_SRC_COLOR
    case 3: return VK_BLEND_FACTOR_ONE_MINUS_SRC_COLOR
    case 4: return VK_BLEND_FACTOR_SRC_ALPHA
    case 5: return VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA
    case 6: return VK_BLEND_FACTOR_DST_COLOR
    case 7: return VK_BLEND_FACTOR_ONE_MINUS_DST_COLOR
    case 8: return VK_BLEND_FACTOR_DST_ALPHA
    case 9: return VK_BLEND_FACTOR_ONE_MINUS_DST_ALPHA
    case 10: return VK_BLEND_FACTOR_SRC_ALPHA_SATURATE
    case 11: return VK_BLEND_FACTOR_CONSTANT_COLOR
    case 12: return VK_BLEND_FACTOR_ONE_MINUS_CONSTANT_COLOR
    case 13: return VK_BLEND_FACTOR_CONSTANT_ALPHA
    case 14: return VK_BLEND_FACTOR_ONE_MINUS_CONSTANT_ALPHA
    case 15: return VK_BLEND_FACTOR_SRC1_COLOR
    case 16: return VK_BLEND_FACTOR_ONE_MINUS_SRC1_COLOR
    case 17: return VK_BLEND_FACTOR_SRC1_ALPHA
    case 18: return VK_BLEND_FACTOR_ONE_MINUS_SRC1_ALPHA
    default: return VK_BLEND_FACTOR_ONE
    }
}

/// `MTLBlendOperation` → `VkBlendOp`.
func vkBlendOp(_ metal: UInt32) -> VkBlendOp {
    switch metal {
    case 1: return VK_BLEND_OP_SUBTRACT
    case 2: return VK_BLEND_OP_REVERSE_SUBTRACT
    case 3: return VK_BLEND_OP_MIN
    case 4: return VK_BLEND_OP_MAX
    default: return VK_BLEND_OP_ADD
    }
}

/// `MTLColorWriteMask` (red 8, green 4, blue 2, alpha 1) → `VkColorComponentFlags` (R 1, G 2, B 4, A 8).
func vkColorWriteMask(_ metal: UInt32) -> VkColorComponentFlags {
    var m: UInt32 = 0
    if metal & 0x8 != 0 { m |= VK_COLOR_COMPONENT_R_BIT.rawValue }
    if metal & 0x4 != 0 { m |= VK_COLOR_COMPONENT_G_BIT.rawValue }
    if metal & 0x2 != 0 { m |= VK_COLOR_COMPONENT_B_BIT.rawValue }
    if metal & 0x1 != 0 { m |= VK_COLOR_COMPONENT_A_BIT.rawValue }
    return m
}

/// `MTLPrimitiveType` → Vulkan topology.
func vkTopology(_ metal: UInt32) -> VkPrimitiveTopology {
    switch metal {
    case 0: return VK_PRIMITIVE_TOPOLOGY_POINT_LIST
    case 1: return VK_PRIMITIVE_TOPOLOGY_LINE_LIST
    case 2: return VK_PRIMITIVE_TOPOLOGY_LINE_STRIP
    case 4: return VK_PRIMITIVE_TOPOLOGY_TRIANGLE_STRIP
    default: return VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST
    }
}

/// The topology class of a primitive type: 1 point, 2 line, 3 triangle
/// (the `MTLPrimitiveTopologyClass` values).
func topologyClass(ofPrimitive metal: UInt32) -> UInt32 {
    switch metal {
    case 0: return 1
    case 1, 2: return 2
    default: return 3
    }
}

func vkTopology(forClass cls: UInt32) -> VkPrimitiveTopology {
    switch cls {
    case 1: return VK_PRIMITIVE_TOPOLOGY_POINT_LIST
    case 2: return VK_PRIMITIVE_TOPOLOGY_LINE_LIST
    default: return VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST
    }
}

/// `MTLSamplerAddressMode` → Vulkan address mode (+ whether it needs a border).
func vkAddressMode(_ metal: UInt8, mirrorClampSupported: Bool) -> VkSamplerAddressMode {
    switch metal {
    case 1: return mirrorClampSupported ? VK_SAMPLER_ADDRESS_MODE_MIRROR_CLAMP_TO_EDGE : VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE
    case 2: return VK_SAMPLER_ADDRESS_MODE_REPEAT
    case 3: return VK_SAMPLER_ADDRESS_MODE_MIRRORED_REPEAT
    case 4, 5: return VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_BORDER
    default: return VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE
    }
}

/// `MTLSamplerBorderColor` → `VkBorderColor`.
func vkBorderColor(_ metal: UInt8) -> VkBorderColor {
    switch metal {
    case 1: return VK_BORDER_COLOR_FLOAT_OPAQUE_BLACK
    case 2: return VK_BORDER_COLOR_FLOAT_OPAQUE_WHITE
    default: return VK_BORDER_COLOR_FLOAT_TRANSPARENT_BLACK
    }
}

/// `MTLTextureSwizzle` (Zero 0, One 1, Red 2, Green 3, Blue 4, Alpha 5) → `VkComponentSwizzle`.
func vkSwizzle(_ metal: UInt8) -> VkComponentSwizzle {
    switch metal {
    case 0: return VK_COMPONENT_SWIZZLE_ZERO
    case 1: return VK_COMPONENT_SWIZZLE_ONE
    case 2: return VK_COMPONENT_SWIZZLE_R
    case 3: return VK_COMPONENT_SWIZZLE_G
    case 4: return VK_COMPONENT_SWIZZLE_B
    case 5: return VK_COMPONENT_SWIZZLE_A
    default: return VK_COMPONENT_SWIZZLE_IDENTITY
    }
}

/// Composes a view swizzle on top of a format's own swizzle (A8 stored as R8).
func composeSwizzle(_ outer: VkComponentMapping, over inner: VkComponentMapping) -> VkComponentMapping {
    func resolve(_ s: VkComponentSwizzle, identity: VkComponentSwizzle) -> VkComponentSwizzle {
        s == VK_COMPONENT_SWIZZLE_IDENTITY ? identity : s
    }
    func pick(_ s: VkComponentSwizzle) -> VkComponentSwizzle {
        switch s {
        case VK_COMPONENT_SWIZZLE_R: return resolve(inner.r, identity: VK_COMPONENT_SWIZZLE_R)
        case VK_COMPONENT_SWIZZLE_G: return resolve(inner.g, identity: VK_COMPONENT_SWIZZLE_G)
        case VK_COMPONENT_SWIZZLE_B: return resolve(inner.b, identity: VK_COMPONENT_SWIZZLE_B)
        case VK_COMPONENT_SWIZZLE_A: return resolve(inner.a, identity: VK_COMPONENT_SWIZZLE_A)
        default: return s
        }
    }
    return VkComponentMapping(r: pick(resolve(outer.r, identity: VK_COMPONENT_SWIZZLE_R)),
                              g: pick(resolve(outer.g, identity: VK_COMPONENT_SWIZZLE_G)),
                              b: pick(resolve(outer.b, identity: VK_COMPONENT_SWIZZLE_B)),
                              a: pick(resolve(outer.a, identity: VK_COMPONENT_SWIZZLE_A)))
}

extension VkComponentMapping: @retroactive Equatable {
    public static func == (a: VkComponentMapping, b: VkComponentMapping) -> Bool {
        a.r == b.r && a.g == b.g && a.b == b.b && a.a == b.a
    }
}
