/// Crate (`.usdc`) format constants: the type numbers of non-array values
/// and the 64-bit value representation. These are interop facts of
/// OpenUSD's open-source binary format (version 0.8.0 is what OpenUSD writes
/// by default; 0.4.0 and later are read here).
enum CrateType: UInt8 {
    case invalid = 0
    case bool = 1, uchar, int, uint, int64, uint64, half, float, double, string, token, asset
    case matrix2d = 13, matrix3d, matrix4d, quatd, quatf, quath
    case vec2d = 19, vec2f, vec2h, vec2i, vec3d, vec3f, vec3h, vec3i, vec4d, vec4f, vec4h, vec4i
    case dictionary = 31
    case tokenListOp = 32, stringListOp, pathListOp, referenceListOp, intListOp, int64ListOp, uintListOp, uint64ListOp
    case pathVector = 40, tokenVector, specifier, permission, variability, variantSelectionMap, timeSamples, payload
    case doubleVector = 48, layerOffsetVector, stringVector, valueBlock, value, unregisteredValue, unregisteredValueListOp
    case payloadListOp = 55, timeCode, pathExpression, relocates, spline, animationBlock
}

/// A crate value representation: bit 63 array, 62 inlined, 61 compressed,
/// 60 array edit, bits 48–55 the type, bits 0–47 the payload.
struct ValueRep: Hashable {
    var data: UInt64

    init(data: UInt64) { self.data = data }

    init(type: CrateType, inlined: Bool = false, array: Bool = false, payload: UInt64 = 0) {
        data = (array ? 1 << 63 : 0) | (inlined ? 1 << 62 : 0) | (UInt64(type.rawValue) << 48) | (payload & 0xFFFF_FFFF_FFFF)
    }

    var isArray: Bool { data & (1 << 63) != 0 }
    var isInlined: Bool { data & (1 << 62) != 0 }
    var isCompressed: Bool { data & (1 << 61) != 0 }
    var isArrayEdit: Bool { data & (1 << 60) != 0 }
    var typeNumber: UInt8 { UInt8(truncatingIfNeeded: data >> 48) }
    var payload: UInt64 { data & 0xFFFF_FFFF_FFFF }

    mutating func setCompressed() { data |= 1 << 61 }
}

struct CrateVersion: Comparable {
    var major: UInt8, minor: UInt8, patch: UInt8

    static func < (a: CrateVersion, b: CrateVersion) -> Bool {
        (a.major, a.minor, a.patch) < (b.major, b.minor, b.patch)
    }
}
