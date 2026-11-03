import Foundation

/// A document that cannot be read (`specs/formats/icon-format.md`: the
/// invalid cases of §3–§6). `path` names the place, like
/// `groups[0].layers[1].blend-mode`.
public struct IconError: Error, CustomStringConvertible, Equatable, Sendable {
    public var path: String
    public var message: String
    public init(_ path: String, _ message: String) {
        self.path = path
        self.message = message
    }
    public var description: String { path.isEmpty ? message : "\(path): \(message)" }
}

/// A value that a key of `icon.json` holds, read from and written to JSON.
public protocol IconValue: Equatable, Sendable {
    init(json: IconJSON, path: String) throws
    var json: IconJSON { get }
}

func sub(_ path: String, _ key: String) -> String { path.isEmpty ? key : "\(path).\(key)" }
func sub(_ path: String, _ index: Int) -> String { "\(path)[\(index)]" }

extension Double: IconValue {
    public init(json: IconJSON, path: String) throws {
        guard let n = json.numberValue else { throw IconError(path, "expected a number") }
        self = n
    }
    public var json: IconJSON { .number(self) }
}

extension Bool: IconValue {
    public init(json: IconJSON, path: String) throws {
        guard let b = json.boolValue else { throw IconError(path, "expected true or false") }
        self = b
    }
    public var json: IconJSON { .bool(self) }
}

extension String: IconValue {
    public init(json: IconJSON, path: String) throws {
        guard let s = json.stringValue else { throw IconError(path, "expected a string") }
        self = s
    }
    public var json: IconJSON { .string(self) }
}

// MARK: Colors (§4.1)

/// `space:c1,c2,…` — four components (R, G, B, A) for the RGB spaces, two
/// (white, A) for the gray spaces.
public struct IconColor: IconValue, CustomStringConvertible, Hashable {
    public enum Space: String, CaseIterable, Sendable {
        case sRGB = "srgb", extendedSRGB = "extended-srgb", displayP3 = "display-p3"
        case gray = "gray", extendedGray = "extended-gray"
        public var componentCount: Int { self == .gray || self == .extendedGray ? 2 : 4 }
        public var isGray: Bool { componentCount == 2 }
    }

    public var space: Space
    public var components: [Double]
    /// The text as read, written back unchanged while the components are.
    var text: String?

    public init(space: Space, components: [Double]) {
        self.space = space
        self.components = components
    }

    public static func srgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> IconColor {
        IconColor(space: .sRGB, components: [r, g, b, a])
    }

    public static func extendedGray(_ w: Double, _ a: Double = 1) -> IconColor {
        IconColor(space: .extendedGray, components: [w, a])
    }

    public init(parsing s: String, path: String = "") throws {
        guard let colon = s.firstIndex(of: ":") else { throw IconError(path, "Invalid color encoding, missing ':' delimiter") }
        guard let space = Space(rawValue: String(s[..<colon])) else { throw IconError(path, "Invalid color space") }
        let parts = s[s.index(after: colon)...].split(separator: ",", omittingEmptySubsequences: false)
        let comps = parts.map { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard comps.count == space.componentCount, !comps.contains(nil) else {
            throw IconError(path, "Invalid color: \(space.rawValue) takes \(space.componentCount) components")
        }
        self.space = space
        self.components = comps.compactMap { $0 }
        self.text = s
    }

    public init(json: IconJSON, path: String) throws {
        guard let s = json.stringValue else { throw IconError(path, "expected a color string") }
        try self.init(parsing: s, path: path)
    }

    /// Icon Composer's form: five decimals per component.
    public var description: String {
        if let text, let read = try? IconColor(parsing: text), read.space == space, read.components == components { return text }
        return space.rawValue + ":" + components.map { String(format: "%.5f", $0) }.joined(separator: ",")
    }

    public var json: IconJSON { .string(description) }

    public static func == (a: IconColor, b: IconColor) -> Bool { a.space == b.space && a.components == b.components }
    public func hash(into h: inout Hasher) {
        h.combine(space)
        h.combine(components)
    }

    /// Red, green, blue, alpha (gray spaces repeat the white value).
    public var rgba: (r: Double, g: Double, b: Double, a: Double) {
        space.isGray ? (components[0], components[0], components[0], components[1])
            : (components[0], components[1], components[2], components[3])
    }
}

// MARK: Fills (§4.2)

public struct IconPoint: Equatable, Sendable, Hashable {
    public var x: Double, y: Double
    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// A linear gradient's direction in unit canvas coordinates (y down).
public struct IconGradientOrientation: Equatable, Sendable, Hashable {
    public var start: IconPoint
    public var stop: IconPoint
    public init(start: IconPoint, stop: IconPoint) {
        self.start = start
        self.stop = stop
    }
    /// Top to bottom, used when `orientation` is absent.
    public static let topToBottom = IconGradientOrientation(start: IconPoint(x: 0.5, y: 0), stop: IconPoint(x: 0.5, y: 1))
}

public enum IconFill: IconValue, Hashable {
    /// The system background (document) or the artwork's own colours (layer).
    case automatic
    case none
    case systemLight
    case systemDark
    case solid(IconColor)
    case automaticGradient(IconColor)
    case linearGradient(IconColor, IconColor, orientation: IconGradientOrientation?)

    static let names: [String: IconFill] = ["automatic": .automatic, "none": .none, "system-light": .systemLight, "system-dark": .systemDark]
    static let oneOf = "A fill should be one of: automatic, none, system-light, system-dark, {solid}, {automatic-gradient}, {linear-gradient}"

    public init(json: IconJSON, path: String) throws {
        if let s = json.stringValue {
            guard let f = Self.names[s] else { throw IconError(path, Self.oneOf) }
            self = f
            return
        }
        guard let o = json.objectValue else { throw IconError(path, Self.oneOf) }
        let kinds = ["solid", "automatic-gradient", "linear-gradient"].filter { o[$0] != nil }
        guard kinds.count == 1 else { throw IconError(path, Self.oneOf) }
        let allowed: Set<String> = kinds[0] == "linear-gradient" ? ["linear-gradient", "orientation"] : [kinds[0]]
        guard Set(o.keys).isSubset(of: allowed) else { throw IconError(path, Self.oneOf) }
        switch kinds[0] {
        case "solid": self = .solid(try IconColor(json: o["solid"]!, path: sub(path, "solid")))
        case "automatic-gradient": self = .automaticGradient(try IconColor(json: o["automatic-gradient"]!, path: sub(path, "automatic-gradient")))
        default:
            let p = sub(path, "linear-gradient")
            guard let stops = o["linear-gradient"]?.arrayValue else { throw IconError(p, "expected an array of two colors") }
            guard stops.count == 2 else { throw IconError(p, "a linear gradient takes exactly two colors, not \(stops.count)") }
            var orientation: IconGradientOrientation?
            if let or = o["orientation"] {
                let op = sub(path, "orientation")
                func point(_ k: String) throws -> IconPoint {
                    guard let pt = or[k]?.objectValue, let x = pt["x"]?.numberValue, let y = pt["y"]?.numberValue else {
                        throw IconError(sub(op, k), "expected {\"x\": n, \"y\": n}")
                    }
                    return IconPoint(x: x, y: y)
                }
                orientation = IconGradientOrientation(start: try point("start"), stop: try point("stop"))
            }
            self = .linearGradient(try IconColor(json: stops[0], path: sub(p, 0)), try IconColor(json: stops[1], path: sub(p, 1)), orientation: orientation)
        }
    }

    public var json: IconJSON {
        switch self {
        case .automatic: .string("automatic")
        case .none: .string("none")
        case .systemLight: .string("system-light")
        case .systemDark: .string("system-dark")
        case .solid(let c): .object(["solid": c.json])
        case .automaticGradient(let c): .object(["automatic-gradient": c.json])
        case .linearGradient(let a, let b, let o):
            o.map { o in
                .object(["linear-gradient": .array([a.json, b.json]), "orientation": .object([
                    "start": .object(["x": .number(o.start.x), "y": .number(o.start.y)]),
                    "stop": .object(["x": .number(o.stop.x), "y": .number(o.stop.y)]),
                ])])
            } ?? .object(["linear-gradient": .array([a.json, b.json])])
        }
    }

    /// For a layer: whether the artwork keeps its own colours.
    public var keepsArtworkColors: Bool { self == .automatic || self == .none || self == .systemLight || self == .systemDark }
}

// MARK: Position (§4.4)

public struct IconPosition: IconValue {
    public var scale: Double
    public var translation: IconPoint
    /// Keys Ycode does not interpret (`relative-translation`, …), kept.
    public var extra: [String: IconJSON]

    public init(scale: Double = 1, translation: IconPoint = IconPoint(x: 0, y: 0), extra: [String: IconJSON] = [:]) {
        self.scale = scale
        self.translation = translation
        self.extra = extra
    }

    public static let identity = IconPosition()

    public init(json: IconJSON, path: String) throws {
        guard var o = json.objectValue else { throw IconError(path, "expected {\"scale\", \"translation-in-points\"}") }
        scale = 1
        translation = IconPoint(x: 0, y: 0)
        if let s = o.removeValue(forKey: "scale") { scale = try Double(json: s, path: sub(path, "scale")) }
        if let t = o.removeValue(forKey: "translation-in-points") {
            guard let a = t.arrayValue, a.count == 2, let x = a[0].numberValue, let y = a[1].numberValue else {
                throw IconError(sub(path, "translation-in-points"), "expected [x, y]")
            }
            translation = IconPoint(x: x, y: y)
        }
        extra = o
    }

    public var json: IconJSON {
        var o = extra
        o["scale"] = .number(scale)
        o["translation-in-points"] = .array([.number(translation.x), .number(translation.y)])
        return .object(o)
    }
}

// MARK: Blend modes (§4.5)

public enum IconBlendMode: String, IconValue, CaseIterable {
    case normal, multiply, screen, overlay, darken, lighten
    case softLight = "soft-light", hardLight = "hard-light", plusDarker = "plus-darker", plusLighter = "plus-lighter"

    public init(json: IconJSON, path: String) throws {
        guard let s = json.stringValue, let m = IconBlendMode(rawValue: s) else { throw IconError(path, "Invalid blend mode") }
        self = m
    }
    public var json: IconJSON { .string(rawValue) }

    /// The compiled number (Core Graphics numbering, `assets-car.md` §7.7).
    public var compiledCode: UInt32 {
        switch self {
        case .normal: 0
        case .multiply: 1
        case .screen: 2
        case .overlay: 3
        case .darken: 4
        case .lighten: 5
        case .softLight: 8
        case .hardLight: 9
        case .plusDarker: 26
        case .plusLighter: 27
        }
    }
}

// MARK: Group glass properties (§3.2)

public struct IconShadow: IconValue {
    public enum Kind: String, CaseIterable, Sendable { case neutral, layerColor = "layer-color", none }
    public var kind: String
    public var opacity: Double
    public var extra: [String: IconJSON]

    public init(kind: Kind = .neutral, opacity: Double = 0.5) {
        self.kind = kind.rawValue
        self.opacity = opacity
        self.extra = [:]
    }

    public static let `default` = IconShadow()

    public init(json: IconJSON, path: String) throws {
        guard var o = json.objectValue else { throw IconError(path, "expected {\"kind\", \"opacity\"}") }
        kind = Kind.neutral.rawValue
        opacity = 0.5
        if let k = o.removeValue(forKey: "kind") { kind = try String(json: k, path: sub(path, "kind")) }
        if let x = o.removeValue(forKey: "opacity") { opacity = try Double(json: x, path: sub(path, "opacity")) }
        extra = o
    }

    public var json: IconJSON {
        var o = extra
        o["kind"] = .string(kind)
        o["opacity"] = .number(opacity)
        return .object(o)
    }

    public var knownKind: Kind? { Kind(rawValue: kind) }
}

public struct IconTranslucency: IconValue {
    public var enabled: Bool
    public var value: Double
    public var extra: [String: IconJSON]

    public init(enabled: Bool = true, value: Double = 0.3) {
        self.enabled = enabled
        self.value = value
        self.extra = [:]
    }

    public static let `default` = IconTranslucency()

    public init(json: IconJSON, path: String) throws {
        guard var o = json.objectValue else { throw IconError(path, "expected {\"enabled\", \"value\"}") }
        enabled = true
        value = 0.3
        if let e = o.removeValue(forKey: "enabled") { enabled = try Bool(json: e, path: sub(path, "enabled")) }
        if let v = o.removeValue(forKey: "value") { value = try Double(json: v, path: sub(path, "value")) }
        extra = o
    }

    public var json: IconJSON {
        var o = extra
        o["enabled"] = .bool(enabled)
        o["value"] = .number(value)
        return .object(o)
    }

    /// The amount that takes effect: 0 when disabled.
    public var effectiveValue: Double { enabled ? value : 0 }
}

public struct IconRefractivity: IconValue {
    public var enabled: Bool
    public var strength: Double
    public var depth: Double
    public var extra: [String: IconJSON]

    public init(enabled: Bool, strength: Double, depth: Double) {
        self.enabled = enabled
        self.strength = strength
        self.depth = depth
        self.extra = [:]
    }

    public static let disabled = IconRefractivity(enabled: false, strength: 0, depth: 0)

    public init(json: IconJSON, path: String) throws {
        guard var o = json.objectValue,
              let e = o.removeValue(forKey: "enabled"), let s = o.removeValue(forKey: "strength"), let d = o.removeValue(forKey: "depth") else {
            throw IconError(path, "refractivity needs enabled, strength and depth")
        }
        enabled = try Bool(json: e, path: sub(path, "enabled"))
        strength = try Double(json: s, path: sub(path, "strength"))
        depth = try Double(json: d, path: sub(path, "depth"))
        extra = o
    }

    public var json: IconJSON {
        var o = extra
        o["enabled"] = .bool(enabled)
        o["strength"] = .number(strength)
        o["depth"] = .number(depth)
        return .object(o)
    }
}

/// `blur-material`: a number 0–1, or `null` (off).
public struct IconBlurMaterial: IconValue {
    public var value: Double?
    public init(_ value: Double?) { self.value = value }
    public init(json: IconJSON, path: String) throws {
        if json.isNull { value = nil; return }
        value = try Double(json: json, path: path)
    }
    public var json: IconJSON { value.map { .number($0) } ?? .null }
    /// The strength that takes effect: 0 for off.
    public var effectiveValue: Double { value ?? 0 }
}

public enum IconLighting: String, IconValue, CaseIterable {
    case individual, combined
    public init(json: IconJSON, path: String) throws {
        guard let s = json.stringValue, let l = IconLighting(rawValue: s) else { throw IconError(path, "Invalid lighting (individual or combined)") }
        self = l
    }
    public var json: IconJSON { .string(rawValue) }
}

/// `specular-highlight-placement`. Unrecognized values are kept, not errors.
public struct IconHighlightPlacement: IconValue, Hashable {
    public static let automatic = IconHighlightPlacement(rawValue: "automatic")
    public static let inside = IconHighlightPlacement(rawValue: "inside")
    public static let outside = IconHighlightPlacement(rawValue: "outside")
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(json: IconJSON, path: String) throws { rawValue = try String(json: json, path: path) }
    public var json: IconJSON { .string(rawValue) }
    public var isKnown: Bool { ["automatic", "inside", "outside"].contains(rawValue) }
    /// The compiled code (`icon-compile.md` §4.2): automatic 0, inside 1 (presumed), outside 2.
    public var compiledCode: UInt32 { rawValue == "outside" ? 2 : rawValue == "inside" ? 1 : 0 }
}
