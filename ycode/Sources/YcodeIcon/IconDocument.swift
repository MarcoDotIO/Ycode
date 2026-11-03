import Foundation

// MARK: Appearances, idioms, platforms (§5, §6)

public enum IconAppearance: String, CaseIterable, Sendable {
    case light, dark, tinted
}

/// The `idiom` of a specialization entry.
public enum IconIdiom: String, CaseIterable, Sendable {
    case square, macOS, watchOS, iOS

    /// `square` is iOS and macOS; the others only their own platform.
    public func applies(to platform: IconPlatform) -> Bool {
        switch self {
        case .square: platform == .iOS || platform == .macOS
        case .macOS: platform == .macOS
        case .watchOS: platform == .watchOS
        case .iOS: platform == .iOS
        }
    }
}

/// The platforms an `.icon` renders for (§8: no tvOS or visionOS).
public enum IconPlatform: String, CaseIterable, Sendable {
    case iOS, macOS, watchOS

    /// The canvas edge in points: 1024 for squares, 1088 for the watch circle.
    public var canvasSize: Double { self == .watchOS ? 1088 : 1024 }
}

/// The six renditions (§7) and the appearance whose entries each uses (§5).
public enum IconRendition: String, CaseIterable, Sendable {
    case `default` = "Default", dark = "Dark"
    case tintedLight = "TintedLight", tintedDark = "TintedDark", clearLight = "ClearLight", clearDark = "ClearDark"

    public var appearance: IconAppearance {
        switch self {
        case .default: .light
        case .dark: .dark
        default: .tinted
        }
    }
}

// MARK: Specializations (§5)

/// One entry of `K-specializations`.
public struct IconSpecialization<Value: IconValue>: Equatable, Sendable {
    public var appearance: IconAppearance?
    public var idiom: IconIdiom?
    public var value: Value
    public var extra: [String: IconJSON]

    public init(appearance: IconAppearance? = nil, idiom: IconIdiom? = nil, value: Value) {
        self.appearance = appearance
        self.idiom = idiom
        self.value = value
        self.extra = [:]
    }

    init(json: IconJSON, path: String) throws {
        guard var o = json.objectValue else { throw IconError(path, "expected a specialization object") }
        if let a = o.removeValue(forKey: "appearance") {
            guard let s = a.stringValue, let ap = IconAppearance(rawValue: s) else { throw IconError(sub(path, "appearance"), "isn't in the correct format: invalid appearance") }
            appearance = ap
        }
        if let i = o.removeValue(forKey: "idiom") {
            guard let s = i.stringValue, let id = IconIdiom(rawValue: s) else { throw IconError(sub(path, "idiom"), "isn't in the correct format: invalid idiom") }
            idiom = id
        }
        guard let v = o.removeValue(forKey: "value") else { throw IconError(path, "specialization without a value") }
        value = try Value(json: v, path: sub(path, "value"))
        extra = o
    }

    var json: IconJSON {
        var o = extra
        if let appearance { o["appearance"] = .string(appearance.rawValue) }
        if let idiom { o["idiom"] = .string(idiom.rawValue) }
        o["value"] = value.json
        return .object(o)
    }

    /// Whether the entry applies to an appearance on a platform.
    public func matches(_ a: IconAppearance, _ p: IconPlatform) -> Bool {
        (appearance == nil || appearance == a) && (idiom.map { $0.applies(to: p) } ?? true)
    }

    /// Ycode's precedence (the spec leaves idiom against appearance open):
    /// an appearance match outranks an idiom match, and a platform's own
    /// idiom outranks `square`.
    var specificity: Int {
        (appearance != nil ? 4 : 0) + (idiom == nil ? 0 : idiom == .square ? 1 : 2)
    }
}

/// A specializable key `K`: its plain value and its `K-specializations`.
public struct IconSpecialized<Value: IconValue>: Equatable, Sendable {
    public var value: Value?
    public var specializations: [IconSpecialization<Value>]?

    public init(_ value: Value? = nil, specializations: [IconSpecialization<Value>]? = nil) {
        self.value = value
        self.specializations = specializations
    }

    public var isAbsent: Bool { value == nil && specializations == nil }

    /// Reads `key` and `key-specializations` out of `o` (removing them).
    init(_ key: String, from o: inout [String: IconJSON], path: String) throws {
        if let v = o.removeValue(forKey: key) { value = try Value(json: v, path: sub(path, key)) }
        let sk = key + "-specializations"
        if let s = o.removeValue(forKey: sk) {
            guard let a = s.arrayValue else { throw IconError(sub(path, sk), "expected an array") }
            specializations = try a.enumerated().map { try IconSpecialization<Value>(json: $0.element, path: sub(sub(path, sk), $0.offset)) }
        }
    }

    func write(_ key: String, into o: inout [String: IconJSON]) {
        if let value { o[key] = value.json }
        if let specializations { o[key + "-specializations"] = .array(specializations.map(\.json)) }
    }

    /// The value for an appearance and platform: the most specific matching
    /// specialization (file order breaks ties), else the plain value; nil
    /// when nothing applies (the caller's default then holds).
    public func resolve(_ appearance: IconAppearance, _ platform: IconPlatform) -> Value? {
        let matching = (specializations ?? []).filter { $0.matches(appearance, platform) }
        if let best = matching.max(by: { $0.specificity < $1.specificity }) {
            // max(by:) returns the last of equals; take the first instead.
            return matching.first { $0.specificity == best.specificity }?.value
        }
        return value
    }

    /// The entry the resolution picked among specializations only.
    func resolveSpecialization(_ appearance: IconAppearance, _ platform: IconPlatform, appearanceOnly: IconAppearance? = nil) -> Value? {
        let matching = (specializations ?? []).filter { $0.matches(appearance, platform) && (appearanceOnly == nil || $0.appearance == appearanceOnly) }
        guard let top = matching.map(\.specificity).max() else { return nil }
        return matching.first { $0.specificity == top }?.value
    }
}

// MARK: Layers (§3.3)

public struct IconLayer: Equatable, Sendable {
    public var name: String?
    public var imageName: IconSpecialized<String>
    public var hidden: IconSpecialized<Bool>
    public var opacity: IconSpecialized<Double>
    public var blendMode: IconSpecialized<IconBlendMode>
    public var position: IconSpecialized<IconPosition>
    public var fill: IconSpecialized<IconFill>
    public var glass: IconSpecialized<Bool>
    public var extra: [String: IconJSON]

    public init(name: String? = nil, imageName: String? = nil) {
        self.name = name
        self.imageName = IconSpecialized(imageName)
        hidden = .init()
        opacity = .init()
        blendMode = .init()
        position = .init()
        fill = .init()
        glass = .init()
        extra = [:]
    }

    init(json: IconJSON, path: String) throws {
        guard var o = json.objectValue else { throw IconError(path, "expected a layer object") }
        if let n = o.removeValue(forKey: "name") { name = try String(json: n, path: sub(path, "name")) }
        imageName = try .init("image-name", from: &o, path: path)
        hidden = try .init("hidden", from: &o, path: path)
        opacity = try .init("opacity", from: &o, path: path)
        blendMode = try .init("blend-mode", from: &o, path: path)
        position = try .init("position", from: &o, path: path)
        fill = try .init("fill", from: &o, path: path)
        glass = try .init("glass", from: &o, path: path)
        extra = o
    }

    public var json: IconJSON {
        var o = extra
        if let name { o["name"] = .string(name) }
        imageName.write("image-name", into: &o)
        hidden.write("hidden", into: &o)
        opacity.write("opacity", into: &o)
        blendMode.write("blend-mode", into: &o)
        position.write("position", into: &o)
        fill.write("fill", into: &o)
        glass.write("glass", into: &o)
        return .object(o)
    }
}

// MARK: Groups (§3.2)

public struct IconGroup: Equatable, Sendable {
    public var name: String?
    public var layers: [IconLayer]
    public var hidden: IconSpecialized<Bool>
    public var opacity: IconSpecialized<Double>
    public var blendMode: IconSpecialized<IconBlendMode>
    public var position: IconSpecialized<IconPosition>
    public var shadow: IconSpecialized<IconShadow>
    public var translucency: IconSpecialized<IconTranslucency>
    public var specular: IconSpecialized<Bool>
    public var specularHighlightPlacement: IconSpecialized<IconHighlightPlacement>
    public var lighting: IconSpecialized<IconLighting>
    public var blurMaterial: IconSpecialized<IconBlurMaterial>
    public var refractivity: IconSpecialized<IconRefractivity>
    public var extra: [String: IconJSON]

    public init(name: String? = nil, layers: [IconLayer] = []) {
        self.name = name
        self.layers = layers
        hidden = .init()
        opacity = .init()
        blendMode = .init()
        position = .init()
        shadow = .init()
        translucency = .init()
        specular = .init()
        specularHighlightPlacement = .init()
        lighting = .init()
        blurMaterial = .init()
        refractivity = .init()
        extra = [:]
    }

    init(json: IconJSON, path: String) throws {
        guard var o = json.objectValue else { throw IconError(path, "expected a group object") }
        if let n = o.removeValue(forKey: "name") { name = try String(json: n, path: sub(path, "name")) }
        guard let l = o.removeValue(forKey: "layers") else { throw IconError(path, "The data couldn't be read because it is missing: layers") }
        guard let la = l.arrayValue else { throw IconError(sub(path, "layers"), "expected an array") }
        layers = try la.enumerated().map { try IconLayer(json: $0.element, path: sub(sub(path, "layers"), $0.offset)) }
        hidden = try .init("hidden", from: &o, path: path)
        opacity = try .init("opacity", from: &o, path: path)
        blendMode = try .init("blend-mode", from: &o, path: path)
        position = try .init("position", from: &o, path: path)
        shadow = try .init("shadow", from: &o, path: path)
        translucency = try .init("translucency", from: &o, path: path)
        specular = try .init("specular", from: &o, path: path)
        specularHighlightPlacement = try .init("specular-highlight-placement", from: &o, path: path)
        lighting = try .init("lighting", from: &o, path: path)
        blurMaterial = try .init("blur-material", from: &o, path: path)
        refractivity = try .init("refractivity", from: &o, path: path)
        extra = o
    }

    public var json: IconJSON {
        var o = extra
        if let name { o["name"] = .string(name) }
        o["layers"] = .array(layers.map(\.json))
        hidden.write("hidden", into: &o)
        opacity.write("opacity", into: &o)
        blendMode.write("blend-mode", into: &o)
        position.write("position", into: &o)
        shadow.write("shadow", into: &o)
        translucency.write("translucency", into: &o)
        specular.write("specular", into: &o)
        specularHighlightPlacement.write("specular-highlight-placement", into: &o)
        lighting.write("lighting", into: &o)
        blurMaterial.write("blur-material", into: &o)
        refractivity.write("refractivity", into: &o)
        return .object(o)
    }
}

// MARK: Supported platforms (§6)

public struct IconSupportedPlatforms: Equatable, Sendable {
    public enum Squares: Equatable, Sendable {
        case shared
        case platforms([IconPlatform])
    }
    public var squares: Squares?
    public var circles: [IconPlatform]?
    public var extra: [String: IconJSON]

    public init(squares: Squares? = nil, circles: [IconPlatform]? = nil) {
        self.squares = squares
        self.circles = circles
        self.extra = [:]
    }

    /// The Xcode multiplatform template's value.
    public static let multiplatform = IconSupportedPlatforms(squares: .shared, circles: [.watchOS])

    init(json: IconJSON, path: String) throws {
        guard var o = json.objectValue else { throw IconError(path, "expected {\"squares\", \"circles\"}") }
        func list(_ v: IconJSON, _ p: String) throws -> [IconPlatform] {
            guard let a = v.arrayValue else { throw IconError(p, "expected an array of platforms") }
            return try a.enumerated().map { e in
                guard let s = e.element.stringValue, let pl = IconPlatform(rawValue: s) else {
                    throw IconError(sub(p, e.offset), "isn't in the correct format: unknown platform")
                }
                return pl
            }
        }
        if let s = o.removeValue(forKey: "squares") {
            if s.stringValue == "shared" { squares = .shared } else { squares = .platforms(try list(s, sub(path, "squares"))) }
        }
        if let c = o.removeValue(forKey: "circles") { circles = try list(c, sub(path, "circles")) }
        extra = o
    }

    var json: IconJSON {
        var o = extra
        switch squares {
        case .shared: o["squares"] = .string("shared")
        case .platforms(let p): o["squares"] = .array(p.map { .string($0.rawValue) })
        case nil: break
        }
        if let circles { o["circles"] = .array(circles.map { .string($0.rawValue) }) }
        return .object(o)
    }

    /// The platforms the editor previews (the build does not filter by them).
    public var platforms: [IconPlatform] {
        var out: [IconPlatform] = []
        switch squares {
        case .shared: out += [.iOS, .macOS]
        case .platforms(let p): out += p
        case nil: break
        }
        out += circles ?? []
        return IconPlatform.allCases.filter(out.contains)
    }
}

// MARK: Document (§3.1)

public struct IconDocument: Equatable, Sendable {
    public var fill: IconSpecialized<IconFill>
    public var groups: [IconGroup]
    public var supportedPlatforms: IconSupportedPlatforms?
    public var colorSpaceForUntaggedSVGColors: String?
    /// Keys Ycode does not interpret (`material-strength`, …), kept.
    public var extra: [String: IconJSON]

    public init(fill: IconFill? = nil, groups: [IconGroup] = [], supportedPlatforms: IconSupportedPlatforms? = nil) {
        self.fill = IconSpecialized(fill)
        self.groups = groups
        self.supportedPlatforms = supportedPlatforms
        self.extra = [:]
    }

    public init(json: IconJSON) throws {
        guard var o = json.objectValue else { throw IconError("", "The data couldn't be read because it isn't in the correct format") }
        guard let g = o.removeValue(forKey: "groups") else { throw IconError("", "The data couldn't be read because it is missing: groups") }
        guard let ga = g.arrayValue else { throw IconError("groups", "expected an array") }
        groups = try ga.enumerated().map { try IconGroup(json: $0.element, path: sub("groups", $0.offset)) }
        fill = try .init("fill", from: &o, path: "")
        if let sp = o.removeValue(forKey: "supported-platforms") { supportedPlatforms = try IconSupportedPlatforms(json: sp, path: "supported-platforms") }
        if let cs = o.removeValue(forKey: "color-space-for-untagged-svg-colors") {
            let p = "color-space-for-untagged-svg-colors"
            let s = try String(json: cs, path: p)
            // Icon Composer rejects "srgb" here (§3.1); the full value set is open.
            guard s != "srgb" else { throw IconError(p, "Invalid color space for untagged SVG colors") }
            colorSpaceForUntaggedSVGColors = s
        }
        extra = o
    }

    public init(data: Data) throws {
        let json: IconJSON
        do { json = try IconJSON.parse(data) } catch { throw IconError("", "The data couldn't be read because it isn't in the correct format (\(error))") }
        try self.init(json: json)
    }

    public var json: IconJSON {
        var o = extra
        fill.write("fill", into: &o)
        o["groups"] = .array(groups.map(\.json))
        if let supportedPlatforms { o["supported-platforms"] = supportedPlatforms.json }
        if let colorSpaceForUntaggedSVGColors { o["color-space-for-untagged-svg-colors"] = .string(colorSpaceForUntaggedSVGColors) }
        return .object(o)
    }

    /// `icon.json` in Icon Composer's layout.
    public func data() -> Data { json.formattedData() }
}
