/// The data types of USD attribute values that can also be arrays.
///
/// The raw values are the type numbers of the crate (`.usdc`) format, an
/// interop fact of OpenUSD's open-source file format.
public enum ValueType: UInt8, Hashable, Sendable, CaseIterable {
    case bool = 1, uchar = 2, int = 3, uint = 4, int64 = 5, uint64 = 6
    case half = 7, float = 8, double = 9
    case string = 10, token = 11, asset = 12
    case matrix2d = 13, matrix3d = 14, matrix4d = 15
    case quatd = 16, quatf = 17, quath = 18
    case vec2d = 19, vec2f = 20, vec2h = 21, vec2i = 22
    case vec3d = 23, vec3f = 24, vec3h = 25, vec3i = 26
    case vec4d = 27, vec4f = 28, vec4h = 29, vec4i = 30
    case timecode = 56
    case pathExpression = 57

    /// How the components of this type are stored in a `Components` buffer.
    public enum Storage: Sendable {
        case bool, integer, float, double, string
    }

    public var storage: Storage {
        switch self {
        case .bool: return .bool
        case .uchar, .int, .uint, .int64, .uint64, .vec2i, .vec3i, .vec4i: return .integer
        case .half, .float, .vec2h, .vec2f, .vec3h, .vec3f, .vec4h, .vec4f, .quath, .quatf: return .float
        case .double, .timecode, .vec2d, .vec3d, .vec4d, .quatd, .matrix2d, .matrix3d, .matrix4d: return .double
        case .string, .token, .asset, .pathExpression: return .string
        }
    }

    /// Scalar components per value: 3 for `float3`, 16 for `matrix4d`.
    public var componentCount: Int {
        switch self {
        case .vec2d, .vec2f, .vec2h, .vec2i: return 2
        case .vec3d, .vec3f, .vec3h, .vec3i: return 3
        case .vec4d, .vec4f, .vec4h, .vec4i, .quatd, .quatf, .quath, .matrix2d: return 4
        case .matrix3d: return 9
        case .matrix4d: return 16
        default: return 1
        }
    }

    /// The base USDA type name (`float3`, `matrix4d`, `token`).
    public var baseName: String {
        switch self {
        case .bool: return "bool"
        case .uchar: return "uchar"
        case .int: return "int"
        case .uint: return "uint"
        case .int64: return "int64"
        case .uint64: return "uint64"
        case .half: return "half"
        case .float: return "float"
        case .double: return "double"
        case .string: return "string"
        case .token: return "token"
        case .asset: return "asset"
        case .matrix2d: return "matrix2d"
        case .matrix3d: return "matrix3d"
        case .matrix4d: return "matrix4d"
        case .quatd: return "quatd"
        case .quatf: return "quatf"
        case .quath: return "quath"
        case .vec2d: return "double2"
        case .vec2f: return "float2"
        case .vec2h: return "half2"
        case .vec2i: return "int2"
        case .vec3d: return "double3"
        case .vec3f: return "float3"
        case .vec3h: return "half3"
        case .vec3i: return "int3"
        case .vec4d: return "double4"
        case .vec4f: return "float4"
        case .vec4h: return "half4"
        case .vec4i: return "int4"
        case .timecode: return "timecode"
        case .pathExpression: return "pathExpression"
        }
    }

    /// True for quaternions (text form `(real, i, j, k)`).
    public var isQuaternion: Bool { self == .quatd || self == .quatf || self == .quath }

    /// True for matrices (text form of nested row tuples).
    public var isMatrix: Bool { self == .matrix2d || self == .matrix3d || self == .matrix4d }

    /// Rows of a matrix type.
    public var matrixRows: Int {
        switch self {
        case .matrix2d: return 2
        case .matrix3d: return 3
        case .matrix4d: return 4
        default: return 0
        }
    }
}

/// A USDA attribute type name: a value type, its role, and whether it is an
/// array (`color3f[]` = vec3f, role Color, array).
public struct TypeName: Hashable, Sendable, CustomStringConvertible {
    public var valueType: ValueType
    /// The role name (`Color`, `Point`, `Normal`, `Vector`, `TextureCoordinate`,
    /// `Frame`, `Group`) or "" for none.
    public var role: String
    public var isArray: Bool
    /// The spelling as authored (`color3f`, `point3f`, `opaque`).
    public var name: String

    public var description: String { name + (isArray ? "[]" : "") }

    public init(valueType: ValueType, role: String = "", isArray: Bool = false, name: String? = nil) {
        self.valueType = valueType
        self.role = role
        self.isArray = isArray
        self.name = name ?? valueType.baseName
    }

    /// Parses `color3f[]`, `token`, `matrix4d` … Unknown names return nil.
    public init?(_ text: String) {
        var base = text
        var array = false
        if base.hasSuffix("[]") {
            array = true
            base.removeLast(2)
        }
        guard let entry = TypeName.table[base] else { return nil }
        self.init(valueType: entry.0, role: entry.1, isArray: array, name: base)
    }

    public var arrayType: TypeName { var t = self; t.isArray = true; return t }
    public var scalarType: TypeName { var t = self; t.isArray = false; return t }

    /// The USDA value type names of OpenUSD's Sdf value type registry.
    static let table: [String: (ValueType, String)] = {
        var t: [String: (ValueType, String)] = [:]
        for v in ValueType.allCases where v != .pathExpression {
            t[v.baseName] = (v, "")
        }
        t["pathExpression"] = (.pathExpression, "")
        t["opaque"] = (.token, "Opaque")
        t["group"] = (.token, "Group")
        for (prefix, role) in [("point", "Point"), ("normal", "Normal"), ("vector", "Vector"), ("color", "Color")] {
            t["\(prefix)3d"] = (.vec3d, role)
            t["\(prefix)3f"] = (.vec3f, role)
            t["\(prefix)3h"] = (.vec3h, role)
        }
        t["color4d"] = (.vec4d, "Color")
        t["color4f"] = (.vec4f, "Color")
        t["color4h"] = (.vec4h, "Color")
        for dim in [2, 3] {
            let vt: [ValueType] = dim == 2 ? [.vec2d, .vec2f, .vec2h] : [.vec3d, .vec3f, .vec3h]
            t["texCoord\(dim)d"] = (vt[0], "TextureCoordinate")
            t["texCoord\(dim)f"] = (vt[1], "TextureCoordinate")
            t["texCoord\(dim)h"] = (vt[2], "TextureCoordinate")
        }
        t["frame4d"] = (.matrix4d, "Frame")
        return t
    }()

    /// The canonical type name for a value type without a role.
    public static func plain(_ type: ValueType, isArray: Bool = false) -> TypeName {
        TypeName(valueType: type, isArray: isArray)
    }
}
