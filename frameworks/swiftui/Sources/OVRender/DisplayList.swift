// The display list (09-open-design.md §3.5): what the view graph lowers to.
// An ordered tree of items, painted back to front. Every item carries a
// stable ID derived from the identity of the view that produced it, so two
// frames can be diffed (DisplayListDiff.swift) and cached rasterisations
// reused. Items are values; images and glyph sources are shared references
// compared by identity.

import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Stable identity of a display item across frames: a hash of the producing
/// view's identity path and the item's index within that view's output.
public struct DisplayItemID: Hashable, Sendable, CustomStringConvertible {
    public var raw: UInt64
    public init(_ raw: UInt64) { self.raw = raw }

    /// Derives a child ID: the same parent and discriminator always give
    /// the same result (FNV-1a over both values).
    public func child(_ discriminator: UInt64) -> DisplayItemID {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for v in [raw, discriminator] {
            var x = v
            for _ in 0..<8 {
                h ^= x & 0xff
                h = h &* 0x0000_0100_0000_01b3
                x >>= 8
            }
        }
        return DisplayItemID(h)
    }

    public func child(_ name: String) -> DisplayItemID {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in name.utf8 {
            h ^= UInt64(b)
            h = h &* 0x0000_0100_0000_01b3
        }
        return child(h)
    }

    public static let root = DisplayItemID(0x6f76_7230_7430_6f74)
    public var description: String { "#" + String(raw, radix: 16) }
}

/// A colour in the sRGB transfer space with straight (not premultiplied)
/// alpha, components 0…1. Extended-range and Display P3 colours are
/// converted to sRGB by the producer; the rasteriser clamps.
public struct RenderColor: Hashable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double
    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }
    public static let clear = RenderColor(red: 0, green: 0, blue: 0, alpha: 0)
    public static let black = RenderColor(red: 0, green: 0, blue: 0)
    public static let white = RenderColor(red: 1, green: 1, blue: 1)

    public func withAlpha(_ a: Double) -> RenderColor {
        RenderColor(red: red, green: green, blue: blue, alpha: alpha * a)
    }

    /// 8-bit components, rounded and clamped.
    public var rgba8: (UInt8, UInt8, UInt8, UInt8) {
        func q(_ v: Double) -> UInt8 { UInt8(max(0, min(255, (v * 255).rounded()))) }
        return (q(red), q(green), q(blue), q(alpha))
    }
}

/// A gradient colour stop; `location` is 0…1.
public struct RenderGradientStop: Hashable, Sendable {
    public var color: RenderColor
    public var location: Double
    public init(color: RenderColor, location: Double) {
        self.color = color
        self.location = location
    }
}

/// What happens outside a gradient's 0…1 range.
public enum RenderSpread: Hashable, Sendable {
    case pad, `repeat`, reflect
}

/// How an area is painted.
public enum RenderPaint: Equatable, Sendable {
    case color(RenderColor)
    /// From `start` (location 0) to `end` (location 1), in the item's
    /// coordinates.
    case linearGradient(stops: [RenderGradientStop], start: CGPoint, end: CGPoint, spread: RenderSpread)
    /// Circles centred on `center`, from `startRadius` (0) to `endRadius` (1).
    case radialGradient(stops: [RenderGradientStop], center: CGPoint, startRadius: Double, endRadius: Double, spread: RenderSpread)
    /// Angular sweep around `center`, from `startAngle` (0) to `endAngle`
    /// (1), radians clockwise from the positive x axis.
    case conicGradient(stops: [RenderGradientStop], center: CGPoint, startAngle: Double, endAngle: Double)

    /// The paint with every colour's alpha multiplied by `opacity`.
    public func multiplyingOpacity(_ opacity: Double) -> RenderPaint {
        if opacity == 1 { return self }
        func m(_ s: [RenderGradientStop]) -> [RenderGradientStop] {
            s.map { RenderGradientStop(color: $0.color.withAlpha(opacity), location: $0.location) }
        }
        switch self {
        case .color(let c): return .color(c.withAlpha(opacity))
        case let .linearGradient(s, a, b, sp): return .linearGradient(stops: m(s), start: a, end: b, spread: sp)
        case let .radialGradient(s, c, r0, r1, sp): return .radialGradient(stops: m(s), center: c, startRadius: r0, endRadius: r1, spread: sp)
        case let .conicGradient(s, c, a0, a1): return .conicGradient(stops: m(s), center: c, startAngle: a0, endAngle: a1)
        }
    }
}

public enum RenderFillRule: Hashable, Sendable {
    case nonZero, evenOdd
}

public enum RenderLineCap: Hashable, Sendable {
    case butt, round, square
}

public enum RenderLineJoin: Hashable, Sendable {
    case miter, round, bevel
}

/// Stroke parameters (lengths in the item's coordinates).
public struct RenderStroke: Equatable, Sendable {
    public var lineWidth: Double
    public var lineCap: RenderLineCap
    public var lineJoin: RenderLineJoin
    public var miterLimit: Double
    public var dash: [Double]
    public var dashPhase: Double
    public init(lineWidth: Double = 1, lineCap: RenderLineCap = .butt, lineJoin: RenderLineJoin = .miter,
                miterLimit: Double = 10, dash: [Double] = [], dashPhase: Double = 0) {
        self.lineWidth = lineWidth
        self.lineCap = lineCap
        self.lineJoin = lineJoin
        self.miterLimit = miterLimit
        self.dash = dash
        self.dashPhase = dashPhase
    }
}

/// Blend modes a group can composite with. The separable and non-separable
/// modes of the W3C Compositing and Blending spec plus `plusLighter`
/// (additive). Porter-Duff operators beyond source-over are not in the
/// display list (the rasteriser has no equivalent; 09 §3.6).
public enum RenderBlendMode: Hashable, Sendable {
    case normal, multiply, screen, overlay, darken, lighten, colorDodge, colorBurn
    case softLight, hardLight, difference, exclusion, hue, saturation, color, luminosity
    case plusLighter
}

/// How an image is sampled when scaled.
public enum RenderInterpolation: Hashable, Sendable {
    case none, low, medium, high
}

/// A clip region of a group: inside the path (or outside with `inverse`).
/// With `stroke`, the region is the path's stroke outline instead of its
/// inside.
public struct RenderClip: Equatable, Sendable {
    public var path: RenderPath
    public var fillRule: RenderFillRule
    public var inverse: Bool
    public var stroke: RenderStroke?
    public init(path: RenderPath, fillRule: RenderFillRule = .nonZero, inverse: Bool = false, stroke: RenderStroke? = nil) {
        self.path = path
        self.fillRule = fillRule
        self.inverse = inverse
        self.stroke = stroke
    }
}

/// A group effect applied to the rendered content of a group.
public enum RenderEffect: Equatable, Sendable {
    /// Gaussian blur, `radius` in points (σ = radius / 2).
    case blur(radius: Double)
    /// A shadow of the content's alpha below the content.
    case shadow(color: RenderColor, radius: Double, x: Double, y: Double)
    /// Multiplies every colour component (premultiplied) by the colour.
    case colorMultiply(RenderColor)
}

/// A run of glyphs from one face at one size. Positions are the glyph
/// origins on the baseline in the item's coordinates.
public struct RenderGlyphRun: Equatable, Sendable {
    public var source: GlyphSourceRef
    public var size: Double
    public var glyphs: [UInt32]
    public var positions: [CGPoint]
    public var paint: RenderPaint
    /// Horizontal shear for synthesised italics (tan of the slant angle).
    public var shear: Double
    public init(source: GlyphSourceRef, size: Double, glyphs: [UInt32], positions: [CGPoint], paint: RenderPaint, shear: Double = 0) {
        self.source = source
        self.size = size
        self.glyphs = glyphs
        self.positions = positions
        self.paint = paint
        self.shear = shear
    }
}

/// Supplies glyph outlines to the rasteriser. SwiftUICore adapts OVText's
/// faces to it; OVRender itself has no font code.
public protocol GlyphOutlineSource: AnyObject, Sendable {
    /// Design units per em.
    var unitsPerEm: Double { get }
    /// The outline of `glyph` in design units, y up (as fonts store it), or
    /// nil for an empty glyph.
    func outline(of glyph: UInt32) -> RenderPath?
}

/// A glyph source compared by identity.
public struct GlyphSourceRef: Hashable, Sendable {
    public let source: any GlyphOutlineSource
    public init(_ source: any GlyphOutlineSource) { self.source = source }
    public static func == (l: GlyphSourceRef, r: GlyphSourceRef) -> Bool { l.source === r.source }
    public func hash(into h: inout Hasher) { h.combine(ObjectIdentifier(source)) }
}

/// One element of a display list.
public struct DisplayItem: Equatable, Sendable {
    public var id: DisplayItemID
    public var content: Content

    public init(id: DisplayItemID, _ content: Content) {
        self.id = id
        self.content = content
    }

    public enum Content: Equatable, Sendable {
        /// Fills the inside of `path`.
        case fill(RenderPath, RenderPaint, RenderFillRule)
        /// Strokes `path`.
        case stroke(RenderPath, RenderPaint, RenderStroke)
        /// Paints glyphs.
        case glyphs(RenderGlyphRun)
        /// Draws `image` scaled into `rect`, multiplied by `opacity`.
        case image(RenderImage, rect: CGRect, interpolation: RenderInterpolation, opacity: Double)
        /// Children drawn into an isolated group, then composited.
        case group(DisplayGroup)
        /// Space reserved for content another component draws (a native
        /// view of the platform host). The rasteriser leaves it untouched.
        case placeholder(rect: CGRect, tag: String)
    }
}

/// A group: children rendered with the group's transform, then clipped,
/// masked, filtered by its effects and composited with its opacity and
/// blend mode.
public struct DisplayGroup: Equatable, Sendable {
    public var transform: RenderTransform
    public var opacity: Double
    public var blendMode: RenderBlendMode
    /// Clips in the group's local coordinates (those of the children,
    /// before `transform`), intersected.
    public var clips: [RenderClip]
    /// An alpha mask in the group's local coordinates: the group shows
    /// where the mask is opaque.
    public var mask: DisplayList?
    public var effects: [RenderEffect]
    /// A hint for the compositor: keep this group's rasterisation in its
    /// own layer, so changes to `transform` and `opacity` only recomposite
    /// (09 §3.6).
    public var isLayer: Bool
    public var children: [DisplayItem]

    public init(transform: RenderTransform = .identity, opacity: Double = 1, blendMode: RenderBlendMode = .normal,
                clips: [RenderClip] = [], mask: DisplayList? = nil, effects: [RenderEffect] = [],
                isLayer: Bool = false, children: [DisplayItem] = []) {
        self.transform = transform
        self.opacity = opacity
        self.blendMode = blendMode
        self.clips = clips
        self.mask = mask
        self.effects = effects
        self.isLayer = isLayer
        self.children = children
    }

    /// True when the group changes nothing about its children.
    public var isPlain: Bool {
        transform.isIdentity && opacity == 1 && blendMode == .normal && clips.isEmpty && mask == nil && effects.isEmpty && !isLayer
    }
}

/// An ordered list of items, painted back to front.
public struct DisplayList: Equatable, Sendable {
    public var items: [DisplayItem]
    public init(_ items: [DisplayItem] = []) { self.items = items }
    public var isEmpty: Bool { items.isEmpty }
}

// MARK: - Translation

extension RenderPaint {
    /// The paint with its geometry moved by (dx, dy).
    public func translated(_ dx: Double, _ dy: Double) -> RenderPaint {
        func t(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x + dx, y: p.y + dy) }
        switch self {
        case .color: return self
        case let .linearGradient(s, a, b, sp): return .linearGradient(stops: s, start: t(a), end: t(b), spread: sp)
        case let .radialGradient(s, c, r0, r1, sp): return .radialGradient(stops: s, center: t(c), startRadius: r0, endRadius: r1, spread: sp)
        case let .conicGradient(s, c, a0, a1): return .conicGradient(stops: s, center: t(c), startAngle: a0, endAngle: a1)
        }
    }
}

extension DisplayItem {
    /// The item moved by (dx, dy): geometry is offset (groups get the
    /// translation prepended to their transform).
    public func translated(_ dx: Double, _ dy: Double) -> DisplayItem {
        if dx == 0 && dy == 0 { return self }
        let tr = RenderTransform.translation(dx, dy)
        var out = self
        switch content {
        case let .fill(path, paint, rule):
            out.content = .fill(path.applying(tr), paint.translated(dx, dy), rule)
        case let .stroke(path, paint, stroke):
            out.content = .stroke(path.applying(tr), paint.translated(dx, dy), stroke)
        case .glyphs(var run):
            run.positions = run.positions.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }
            run.paint = run.paint.translated(dx, dy)
            out.content = .glyphs(run)
        case let .image(img, rect, interpolation, opacity):
            out.content = .image(img, rect: rect.offsetBy(dx: dx, dy: dy), interpolation: interpolation, opacity: opacity)
        case .group(var g):
            g.transform = tr.concatenating(g.transform)
            out.content = .group(g)
        case let .placeholder(rect, tag):
            out.content = .placeholder(rect: rect.offsetBy(dx: dx, dy: dy), tag: tag)
        }
        return out
    }
}

// MARK: - Colour multiplication

extension RenderColor {
    public func multiplied(by m: RenderColor) -> RenderColor {
        RenderColor(red: red * m.red, green: green * m.green, blue: blue * m.blue, alpha: alpha * m.alpha)
    }
}

extension RenderPaint {
    public func multiplied(by m: RenderColor) -> RenderPaint {
        func ms(_ s: [RenderGradientStop]) -> [RenderGradientStop] { s.map { RenderGradientStop(color: $0.color.multiplied(by: m), location: $0.location) } }
        switch self {
        case .color(let c): return .color(c.multiplied(by: m))
        case let .linearGradient(s, a, b, sp): return .linearGradient(stops: ms(s), start: a, end: b, spread: sp)
        case let .radialGradient(s, c, r0, r1, sp): return .radialGradient(stops: ms(s), center: c, startRadius: r0, endRadius: r1, spread: sp)
        case let .conicGradient(s, c, a0, a1): return .conicGradient(stops: ms(s), center: c, startAngle: a0, endAngle: a1)
        }
    }
}

extension DisplayItem {
    /// The item with every paint multiplied by `m` (images keep their
    /// pixels: the rasteriser has no per-pixel colour filter).
    public func multiplyingColors(by m: RenderColor) -> DisplayItem {
        var out = self
        switch content {
        case let .fill(p, paint, r): out.content = .fill(p, paint.multiplied(by: m), r)
        case let .stroke(p, paint, s): out.content = .stroke(p, paint.multiplied(by: m), s)
        case .glyphs(var run):
            run.paint = run.paint.multiplied(by: m)
            out.content = .glyphs(run)
        case .group(var g):
            g.children = g.children.map { $0.multiplyingColors(by: m) }
            out.content = .group(g)
        case .image, .placeholder: break
        }
        return out
    }
}
