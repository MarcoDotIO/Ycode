/// Flat component storage for scalar and array values. A `float3[]` of two
/// elements is `.floats([x0, y0, z0, x1, y1, z1])`. Half values are kept as
/// `Float` (exact); 64-bit unsigned values are kept by bit pattern.
/// Quaternions are stored in text order: real, i, j, k.
public enum Components: Hashable, Sendable {
    case bools([Bool])
    case integers([Int64])
    case floats([Float])
    case doubles([Double])
    case strings([String])

    public var count: Int {
        switch self {
        case .bools(let a): return a.count
        case .integers(let a): return a.count
        case .floats(let a): return a.count
        case .doubles(let a): return a.count
        case .strings(let a): return a.count
        }
    }

    /// Numeric components as doubles (strings: empty; bools: 0/1).
    public var doubles: [Double] {
        switch self {
        case .bools(let a): return a.map { $0 ? 1 : 0 }
        case .integers(let a): return a.map { Double($0) }
        case .floats(let a): return a.map { Double($0) }
        case .doubles(let a): return a
        case .strings: return []
        }
    }

    public var strings: [String] {
        if case .strings(let a) = self { return a }
        return []
    }

    /// Empty storage of the right kind for a value type.
    public static func empty(for type: ValueType) -> Components {
        switch type.storage {
        case .bool: return .bools([])
        case .integer: return .integers([])
        case .float: return .floats([])
        case .double: return .doubles([])
        case .string: return .strings([])
        }
    }

    /// Builds storage for a value type from doubles (numeric types only).
    public static func from(doubles: [Double], as type: ValueType) -> Components {
        switch type.storage {
        case .bool: return .bools(doubles.map { $0 != 0 })
        case .integer: return .integers(doubles.map { Int64($0) })
        case .float: return .floats(doubles.map { Float($0) })
        case .double: return .doubles(doubles)
        case .string: return .strings(doubles.map { String($0) })
        }
    }

    /// The components of element `index` for a type with `width` components.
    public func slice(_ index: Int, width: Int) -> Components {
        let r = (index * width)..<((index + 1) * width)
        switch self {
        case .bools(let a): return .bools(Array(a[r]))
        case .integers(let a): return .integers(Array(a[r]))
        case .floats(let a): return .floats(Array(a[r]))
        case .doubles(let a): return .doubles(Array(a[r]))
        case .strings(let a): return .strings(Array(a[r]))
        }
    }
}

public enum Specifier: UInt32, Hashable, Sendable, CaseIterable {
    case def = 0, over = 1, `class` = 2

    public var keyword: String {
        switch self {
        case .def: return "def"
        case .over: return "over"
        case .class: return "class"
        }
    }
}

public enum Permission: UInt32, Hashable, Sendable {
    case `public` = 0, `private` = 1
}

public enum Variability: UInt32, Hashable, Sendable {
    case varying = 0, uniform = 1
}

/// A time offset and scale applied to a sublayer, reference or payload.
public struct LayerOffset: Hashable, Sendable {
    public var offset: Double
    public var scale: Double

    public init(offset: Double = 0, scale: Double = 1) {
        self.offset = offset
        self.scale = scale
    }

    public static let identity = LayerOffset()
    public var isIdentity: Bool { offset == 0 && scale == 1 }

    /// Maps a time in the target layer into the referencing layer.
    public func apply(_ time: Double) -> Double { time * scale + offset }

    /// The composition of two offsets: `self` applied after `inner`.
    public func concatenating(_ inner: LayerOffset) -> LayerOffset {
        LayerOffset(offset: offset + scale * inner.offset, scale: scale * inner.scale)
    }
}

/// A reference arc: an asset path (empty for an internal reference), an
/// optional prim path (empty: the target layer's `defaultPrim`), a layer
/// offset and custom data.
public struct Reference: Hashable, Sendable {
    public var assetPath: String
    public var primPath: Path
    public var layerOffset: LayerOffset
    public var customData: [String: Value]

    public init(assetPath: String = "", primPath: Path = .empty, layerOffset: LayerOffset = .identity, customData: [String: Value] = [:]) {
        self.assetPath = assetPath
        self.primPath = primPath
        self.layerOffset = layerOffset
        self.customData = customData
    }
}

/// A payload arc (a deferred-load reference without custom data).
public struct Payload: Hashable, Sendable {
    public var assetPath: String
    public var primPath: Path
    public var layerOffset: LayerOffset

    public init(assetPath: String = "", primPath: Path = .empty, layerOffset: LayerOffset = .identity) {
        self.assetPath = assetPath
        self.primPath = primPath
        self.layerOffset = layerOffset
    }
}

/// One time sample; the value may be `.valueBlock`.
public struct TimeSample: Hashable, Sendable {
    public var time: Double
    public var value: Value

    public init(time: Double, value: Value) {
        self.time = time
        self.value = value
    }
}

/// The ordered list edits of USD list fields (references, apiSchemas,
/// relationship targets…). An explicit list replaces weaker opinions; the
/// other lists edit them.
public struct ListOp<Item: Hashable & Sendable>: Hashable, Sendable {
    public var isExplicit: Bool
    public var explicitItems: [Item]
    public var addedItems: [Item]
    public var prependedItems: [Item]
    public var appendedItems: [Item]
    public var deletedItems: [Item]
    public var orderedItems: [Item]

    public init(isExplicit: Bool = false, explicitItems: [Item] = [], addedItems: [Item] = [], prependedItems: [Item] = [],
                appendedItems: [Item] = [], deletedItems: [Item] = [], orderedItems: [Item] = []) {
        self.isExplicit = isExplicit
        self.explicitItems = explicitItems
        self.addedItems = addedItems
        self.prependedItems = prependedItems
        self.appendedItems = appendedItems
        self.deletedItems = deletedItems
        self.orderedItems = orderedItems
    }

    public static func explicit(_ items: [Item]) -> ListOp { ListOp(isExplicit: true, explicitItems: items) }
    public static func prepended(_ items: [Item]) -> ListOp { ListOp(prependedItems: items) }
    public static func appended(_ items: [Item]) -> ListOp { ListOp(appendedItems: items) }

    /// Applies this list op to a weaker list.
    public func applied(to weaker: [Item]) -> [Item] {
        if isExplicit { return explicitItems }
        var result = weaker
        if !deletedItems.isEmpty { result.removeAll { deletedItems.contains($0) } }
        for item in addedItems where !result.contains(item) { result.append(item) }
        if !prependedItems.isEmpty {
            result.removeAll { prependedItems.contains($0) }
            result.insert(contentsOf: prependedItems, at: 0)
        }
        if !appendedItems.isEmpty {
            result.removeAll { appendedItems.contains($0) }
            result.append(contentsOf: appendedItems)
        }
        if !orderedItems.isEmpty {
            let ordered = orderedItems.filter { result.contains($0) }
            var iterator = ordered.makeIterator()
            result = result.map { ordered.contains($0) ? iterator.next()! : $0 }
        }
        return result
    }

    /// Every item mentioned by any list (for dependency scans).
    public var allItems: [Item] {
        explicitItems + addedItems + prependedItems + appendedItems + deletedItems + orderedItems
    }

    public var isEmpty: Bool { !isExplicit && allItems.isEmpty }
}

/// A USD value: everything a spec field can hold.
public indirect enum Value: Hashable, Sendable {
    /// One value of a data type (`float3 (1, 2, 3)`).
    case scalar(ValueType, Components)
    /// An array of a data type.
    case array(ValueType, Components)
    /// `dictionary` (customData, assetInfo…); keys are written sorted.
    case dictionary([String: Value])
    case tokenListOp(ListOp<String>)
    case stringListOp(ListOp<String>)
    case pathListOp(ListOp<Path>)
    case referenceListOp(ListOp<Reference>)
    case payloadListOp(ListOp<Payload>)
    /// Integer list ops; the value type is `.int`, `.int64`, `.uint` or `.uint64`.
    case integerListOp(ValueType, ListOp<Int64>)
    case path(Path)
    case pathVector([Path])
    case tokenVector([String])
    case stringVector([String])
    case doubleVector([Double])
    case layerOffsetVector([LayerOffset])
    case specifier(Specifier)
    case permission(Permission)
    case variability(Variability)
    case variantSelectionMap([String: String])
    case timeSamples([TimeSample])
    case payload(Payload)
    /// `None`: blocks weaker opinions.
    case valueBlock

    // MARK: Constructors

    public static func bool(_ v: Bool) -> Value { .scalar(.bool, .bools([v])) }
    public static func int(_ v: Int) -> Value { .scalar(.int, .integers([Int64(v)])) }
    public static func int64(_ v: Int64) -> Value { .scalar(.int64, .integers([v])) }
    public static func uint(_ v: UInt32) -> Value { .scalar(.uint, .integers([Int64(v)])) }
    public static func float(_ v: Float) -> Value { .scalar(.float, .floats([v])) }
    public static func half(_ v: Float) -> Value { .scalar(.half, .floats([Half.round(v)])) }
    public static func double(_ v: Double) -> Value { .scalar(.double, .doubles([v])) }
    public static func timecode(_ v: Double) -> Value { .scalar(.timecode, .doubles([v])) }
    public static func string(_ v: String) -> Value { .scalar(.string, .strings([v])) }
    public static func token(_ v: String) -> Value { .scalar(.token, .strings([v])) }
    public static func asset(_ v: String) -> Value { .scalar(.asset, .strings([v])) }
    public static func float2(_ x: Float, _ y: Float) -> Value { .scalar(.vec2f, .floats([x, y])) }
    public static func float3(_ x: Float, _ y: Float, _ z: Float) -> Value { .scalar(.vec3f, .floats([x, y, z])) }
    public static func double3(_ x: Double, _ y: Double, _ z: Double) -> Value { .scalar(.vec3d, .doubles([x, y, z])) }
    public static func quatf(real: Float, _ i: Float, _ j: Float, _ k: Float) -> Value { .scalar(.quatf, .floats([real, i, j, k])) }
    public static func matrix4d(_ m: [Double]) -> Value { .scalar(.matrix4d, .doubles(m)) }
    public static func tokens(_ v: [String]) -> Value { .array(.token, .strings(v)) }
    public static func strings(_ v: [String]) -> Value { .array(.string, .strings(v)) }
    public static func ints(_ v: [Int]) -> Value { .array(.int, .integers(v.map(Int64.init))) }
    public static func floats(_ v: [Float]) -> Value { .array(.float, .floats(v)) }
    public static func doubles(_ v: [Double]) -> Value { .array(.double, .doubles(v)) }
    public static func float3s(_ v: [Float]) -> Value { .array(.vec3f, .floats(v)) }

    /// A scalar of `type` from numeric components.
    public static func numeric(_ type: ValueType, _ components: [Double]) -> Value {
        .scalar(type, .from(doubles: components, as: type))
    }

    // MARK: Accessors

    /// The value type of a scalar or array.
    public var valueType: ValueType? {
        switch self {
        case .scalar(let t, _), .array(let t, _): return t
        default: return nil
        }
    }

    public var isArray: Bool {
        if case .array = self { return true }
        return false
    }

    public var components: Components? {
        switch self {
        case .scalar(_, let c), .array(_, let c): return c
        default: return nil
        }
    }

    public var boolValue: Bool? {
        if case .scalar(.bool, .bools(let a)) = self { return a.first }
        return nil
    }

    /// A numeric scalar (bool, integer or floating point) as a double.
    public var doubleValue: Double? {
        guard case .scalar(let t, let c) = self, t.componentCount == 1, t.storage != .string else { return nil }
        return c.doubles.first
    }

    /// A string, token or asset path scalar.
    public var stringValue: String? {
        if case .scalar(let t, .strings(let a)) = self, t.storage == .string { return a.first }
        return nil
    }

    /// All numeric components as doubles (vectors, matrices, arrays).
    public var doubleComponents: [Double]? {
        guard let c = components else { return nil }
        if case .strings = c { return nil }
        return c.doubles
    }

    /// A string, token or asset array, or a token/string vector.
    public var stringArray: [String]? {
        switch self {
        case .array(_, .strings(let a)): return a
        case .tokenVector(let a), .stringVector(let a): return a
        default: return nil
        }
    }

    /// Number of elements in an array value.
    public var arrayCount: Int? {
        guard case .array(let t, let c) = self else { return nil }
        return c.count / max(t.componentCount, 1)
    }
}

/// IEEE 754 binary16 conversion (the `half` types).
public enum Half {
    public static func toFloat(_ bits: UInt16) -> Float {
        let sign = UInt32(bits & 0x8000) << 16
        let exponent = Int((bits >> 10) & 0x1F)
        let mantissa = UInt32(bits & 0x3FF)
        if exponent == 0 {
            if mantissa == 0 { return Float(bitPattern: sign) }
            // Subnormal: value = mantissa * 2^-24.
            let value = Float(mantissa) * Float(sign: .plus, exponent: -24, significand: 1)
            return sign != 0 ? -value : value
        }
        if exponent == 31 {
            return Float(bitPattern: sign | 0x7F80_0000 | (mantissa << 13))
        }
        return Float(bitPattern: sign | (UInt32(exponent - 15 + 127) << 23) | (mantissa << 13))
    }

    /// Round-to-nearest-even conversion to binary16.
    public static func fromFloat(_ value: Float) -> UInt16 {
        let bits = value.bitPattern
        let sign = UInt16((bits >> 16) & 0x8000)
        let exponent = Int((bits >> 23) & 0xFF)
        var mantissa = bits & 0x7F_FFFF
        if exponent == 0xFF {
            return sign | 0x7C00 | (mantissa != 0 ? 0x200 : 0)
        }
        let e = exponent - 127 + 15
        if e >= 31 { return sign | 0x7C00 }
        if e <= 0 {
            if e < -10 { return sign }
            mantissa |= 0x80_0000
            let shift = UInt32(14 - e)
            var half = mantissa >> shift
            let remainder = mantissa & ((1 << shift) - 1)
            let halfway = UInt32(1) << (shift - 1)
            if remainder > halfway || (remainder == halfway && (half & 1) == 1) { half += 1 }
            return sign | UInt16(half)
        }
        var half = UInt32(e) << 10 | (mantissa >> 13)
        let remainder = mantissa & 0x1FFF
        if remainder > 0x1000 || (remainder == 0x1000 && (half & 1) == 1) { half += 1 }
        return sign | UInt16(half)
    }

    /// Rounds a float to the nearest half value.
    public static func round(_ value: Float) -> Float { toFloat(fromFloat(value)) }
}
