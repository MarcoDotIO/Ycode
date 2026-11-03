import Foundation

// MARK: Effective values (defaults applied, §3, §5)

public struct IconSize: Equatable, Sendable, Hashable {
    public var width: Double, height: Double
    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }
}

/// A frame in canvas points, top-left origin, y down.
public struct IconRect: Equatable, Sendable, Hashable, CustomStringConvertible {
    public var x: Double, y: Double, width: Double, height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
    public var description: String { "(\(IconJSON.format(x)), \(IconJSON.format(y)), \(IconJSON.format(width)), \(IconJSON.format(height)))" }
}

public struct ResolvedLayer: Equatable, Sendable {
    public var name: String?
    public var imageName: String?
    public var hidden: Bool
    public var opacity: Double
    public var blendMode: IconBlendMode
    public var position: IconPosition
    public var fill: IconFill
    public var glass: Bool
}

public struct ResolvedGroup: Equatable, Sendable {
    public var name: String?
    public var hidden: Bool
    public var opacity: Double
    public var blendMode: IconBlendMode
    public var position: IconPosition
    public var shadow: IconShadow
    public var translucency: IconTranslucency
    public var specular: Bool
    public var specularHighlightPlacement: IconHighlightPlacement
    public var lighting: IconLighting
    public var blurMaterial: IconBlurMaterial
    public var refractivity: IconRefractivity
    /// Every layer, front-most first, hidden ones included.
    public var layers: [ResolvedLayer]

    public var visibleLayers: [ResolvedLayer] { layers.filter { !$0.hidden } }
}

/// The document as one appearance on one platform sees it.
public struct ResolvedIcon: Equatable, Sendable {
    public var appearance: IconAppearance
    public var platform: IconPlatform
    /// The canvas background after defaults: never nil.
    public var background: IconFill
    /// Every group, front-most first, hidden ones included.
    public var groups: [ResolvedGroup]

    public var visibleGroups: [ResolvedGroup] { groups.filter { !$0.hidden } }
    public var canvasSize: Double { platform.canvasSize }
}

extension IconLayer {
    public func resolved(_ a: IconAppearance, _ p: IconPlatform) -> ResolvedLayer {
        ResolvedLayer(name: name, imageName: imageName.resolve(a, p), hidden: hidden.resolve(a, p) ?? false,
                      opacity: opacity.resolve(a, p) ?? 1, blendMode: blendMode.resolve(a, p) ?? .normal,
                      position: position.resolve(a, p) ?? .identity, fill: fill.resolve(a, p) ?? .automatic,
                      glass: glass.resolve(a, p) ?? true)
    }
}

extension IconGroup {
    public func resolved(_ a: IconAppearance, _ p: IconPlatform) -> ResolvedGroup {
        ResolvedGroup(name: name, hidden: hidden.resolve(a, p) ?? false, opacity: opacity.resolve(a, p) ?? 1,
                      blendMode: blendMode.resolve(a, p) ?? .normal, position: position.resolve(a, p) ?? .identity,
                      shadow: shadow.resolve(a, p) ?? .default, translucency: translucency.resolve(a, p) ?? .default,
                      specular: specular.resolve(a, p) ?? true,
                      specularHighlightPlacement: specularHighlightPlacement.resolve(a, p) ?? .automatic,
                      lighting: lighting.resolve(a, p) ?? .individual, blurMaterial: blurMaterial.resolve(a, p) ?? IconBlurMaterial(nil),
                      refractivity: refractivity.resolve(a, p) ?? .disabled,
                      layers: layers.map { $0.resolved(a, p) })
    }
}

extension IconDocument {
    /// The background for an appearance (§3.1, `icon-compile.md` §4.2):
    /// light and tinted use their entry, else the plain fill, else white;
    /// dark uses a dark entry, else the system dark gradient (the compiled
    /// output gives a document with only a plain fill `system-dark` in dark).
    public func background(_ a: IconAppearance, _ p: IconPlatform) -> IconFill {
        switch a {
        case .dark:
            return fill.resolveSpecialization(.dark, p, appearanceOnly: .dark) ?? .systemDark
        case .light, .tinted:
            return fill.resolve(a, p) ?? .solid(.extendedGray(1))
        }
    }

    public func resolved(_ a: IconAppearance, _ p: IconPlatform) -> ResolvedIcon {
        ResolvedIcon(appearance: a, platform: p, background: background(a, p), groups: groups.map { $0.resolved(a, p) })
    }

    public func resolved(_ r: IconRendition, _ p: IconPlatform) -> ResolvedIcon { resolved(r.appearance, p) }

    /// The effective value of a key for an appearance and platform, with the
    /// defaults of §3 (`value(for:appearance:idiom:)` of the ICON-READER
    /// round). `key` is a document key (`fill`), or `groups[i].<key>` /
    /// `groups[i].layers[j].<key>`. Nil for an unknown key or index.
    public func value(for key: String, appearance a: IconAppearance, platform p: IconPlatform) -> IconJSON? {
        let r = resolved(a, p)
        let parts = key.split(separator: ".").map(String.init)
        func index(_ s: String, _ name: String) -> Int? {
            guard s.hasPrefix(name + "["), s.hasSuffix("]") else { return nil }
            return Int(s.dropFirst(name.count + 1).dropLast())
        }
        if parts.count == 1 { return r.json.objectValue?[parts[0]] }
        guard let gi = index(parts[0], "groups"), r.groups.indices.contains(gi) else { return nil }
        let g = r.groups[gi]
        if parts.count == 2 { return g.json.objectValue?[parts[1]] }
        guard parts.count == 3, let li = index(parts[1], "layers"), g.layers.indices.contains(li) else { return nil }
        return g.layers[li].json.objectValue?[parts[2]]
    }
}

// MARK: Resolved views as JSON (for `ycode assets icon to-json --resolved`)

extension ResolvedLayer {
    public var json: IconJSON {
        var o: [String: IconJSON] = ["hidden": .bool(hidden), "opacity": .number(opacity), "blend-mode": blendMode.json,
                                     "position": position.json, "fill": fill.json, "glass": .bool(glass)]
        if let name { o["name"] = .string(name) }
        if let imageName { o["image-name"] = .string(imageName) }
        return .object(o)
    }
}

extension ResolvedGroup {
    public var json: IconJSON {
        var o: [String: IconJSON] = [
            "hidden": .bool(hidden), "opacity": .number(opacity), "blend-mode": blendMode.json, "position": position.json,
            "shadow": shadow.json, "translucency": translucency.json, "specular": .bool(specular),
            "specular-highlight-placement": specularHighlightPlacement.json, "lighting": lighting.json,
            "blur-material": blurMaterial.json, "refractivity": refractivity.json, "layers": .array(layers.map(\.json)),
        ]
        if let name { o["name"] = .string(name) }
        return .object(o)
    }
}

extension ResolvedIcon {
    public var json: IconJSON {
        .object(["appearance": .string(appearance.rawValue), "platform": .string(platform.rawValue),
                 "fill": background.json, "groups": .array(groups.map(\.json))])
    }

    /// Visible groups bottom first, as the compiled stack lists them
    /// (`icon-compile.md` §4.2).
    public var groupsBottomFirst: [ResolvedGroup] { visibleGroups.reversed() }
}

// MARK: Frames (§4.4)

public enum IconGeometry {
    /// A layer's frame on the canvas: the layer's own scale and translation
    /// about the canvas centre, then the group's.
    public static func layerFrame(natural: IconSize, layer: IconPosition, group: IconPosition, canvas: Double) -> IconRect {
        let c = canvas / 2
        let s = layer.scale * group.scale
        let w = natural.width * s, h = natural.height * s
        let cx = c + layer.translation.x * group.scale + group.translation.x
        let cy = c + layer.translation.y * group.scale + group.translation.y
        return IconRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h)
    }
}

// MARK: Backgrounds (§4.3)

/// A colour stop of a background, in unit canvas coordinates.
public struct IconGradientStop: Equatable, Sendable {
    public var location: Double
    public var color: IconColor
}

/// A background as colours: one stop for a flat fill, two for a gradient.
public struct IconBackground: Equatable, Sendable {
    public var stops: [IconGradientStop]
    public var orientation: IconGradientOrientation

    /// The built-in backgrounds' compiled colours.
    public static let white = IconBackground(stops: [IconGradientStop(location: 0, color: .extendedGray(1))], orientation: .topToBottom)
    public static let systemLight = IconBackground(stops: [IconGradientStop(location: 0, color: IconColor(space: .gray, components: [1, 1])),
                                                           IconGradientStop(location: 1, color: IconColor(space: .gray, components: [0.925, 1]))],
                                                   orientation: .topToBottom)
    public static let systemDark = IconBackground(stops: [IconGradientStop(location: 0, color: IconColor(space: .gray, components: [0.192, 1])),
                                                          IconGradientStop(location: 1, color: IconColor(space: .gray, components: [0.078, 1]))],
                                                  orientation: .topToBottom)

    /// The colours of a resolved document fill. An automatic gradient is
    /// approximated as the colour at the top and 90 % of it at the bottom
    /// (the system's derivation is not specified).
    public init(_ fill: IconFill, appearance: IconAppearance) {
        switch fill {
        case .automatic, .none:
            self = appearance == .dark ? .systemDark : .systemLight
        case .systemLight: self = .systemLight
        case .systemDark: self = .systemDark
        case .solid(let c): self.init(stops: [IconGradientStop(location: 0, color: c)], orientation: .topToBottom)
        case .automaticGradient(let c):
            let (r, g, b, a) = c.rgba
            let bottom = IconColor(space: c.space.isGray ? .extendedSRGB : c.space, components: [r * 0.9, g * 0.9, b * 0.9, a])
            self.init(stops: [IconGradientStop(location: 0, color: c), IconGradientStop(location: 1, color: bottom)], orientation: .topToBottom)
        case .linearGradient(let a, let b, let o):
            self.init(stops: [IconGradientStop(location: 0, color: a), IconGradientStop(location: 1, color: b)], orientation: o ?? .topToBottom)
        }
    }

    public init(stops: [IconGradientStop], orientation: IconGradientOrientation) {
        self.stops = stops
        self.orientation = orientation
    }

    /// The colour at a unit canvas point (projected on the gradient's axis).
    public func color(atX x: Double, y: Double) -> (r: Double, g: Double, b: Double, a: Double) {
        guard stops.count > 1 else { return stops.first?.color.rgba ?? (1, 1, 1, 1) }
        let dx = orientation.stop.x - orientation.start.x, dy = orientation.stop.y - orientation.start.y
        let len2 = dx * dx + dy * dy
        let t = len2 == 0 ? 0 : min(max(((x - orientation.start.x) * dx + (y - orientation.start.y) * dy) / len2, 0), 1)
        let a = stops[0].color.rgba, b = stops[stops.count - 1].color.rgba
        return (a.r + (b.r - a.r) * t, a.g + (b.g - a.g) * t, a.b + (b.b - a.b) * t, a.a + (b.a - a.a) * t)
    }
}
