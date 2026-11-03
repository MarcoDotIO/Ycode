import Foundation
import OVRender

// `Canvas` and `GraphicsContext` (round R5): immediate-mode drawing that
// records display-list items. A context is a value: copies share the
// drawing but keep their own state (transform, opacity, blend mode, clips,
// filters). Clips are kept in canvas coordinates.

/// Records drawing commands into display items.
package final class GraphicsRecording {
    package var items: [DisplayItem] = []
    package let id: DisplayItemID
    private var counter: UInt64 = 0
    package init(id: DisplayItemID) { self.id = id }
    package func nextID() -> DisplayItemID {
        counter += 1
        return id.child(counter)
    }
}

/// A drawing destination with state.
public struct GraphicsContext {
    package var recording: GraphicsRecording
    public var environment: EnvironmentValues
    public var opacity: Double = 1
    public var blendMode: BlendMode = .normal
    public var transform: CGAffineTransform = .identity
    package var clips: [RenderClip] = []
    package var effects: [RenderEffect] = []
    package var size: CGSize

    package init(recording: GraphicsRecording, environment: EnvironmentValues, size: CGSize) {
        self.recording = recording
        self.environment = environment
        self.size = size
    }

    // MARK: Types

    /// Compositing modes of drawing operations.
    public struct BlendMode: RawRepresentable, Equatable, Sendable {
        public let rawValue: Int32
        public init(rawValue: Int32) { self.rawValue = rawValue }
        public static let normal = BlendMode(rawValue: 0)
        public static let multiply = BlendMode(rawValue: 1)
        public static let screen = BlendMode(rawValue: 2)
        public static let overlay = BlendMode(rawValue: 3)
        public static let darken = BlendMode(rawValue: 4)
        public static let lighten = BlendMode(rawValue: 5)
        public static let colorDodge = BlendMode(rawValue: 6)
        public static let colorBurn = BlendMode(rawValue: 7)
        public static let softLight = BlendMode(rawValue: 8)
        public static let hardLight = BlendMode(rawValue: 9)
        public static let difference = BlendMode(rawValue: 10)
        public static let exclusion = BlendMode(rawValue: 11)
        public static let hue = BlendMode(rawValue: 12)
        public static let saturation = BlendMode(rawValue: 13)
        public static let color = BlendMode(rawValue: 14)
        public static let luminosity = BlendMode(rawValue: 15)
        public static let clear = BlendMode(rawValue: 16)
        public static let copy = BlendMode(rawValue: 17)
        public static let sourceIn = BlendMode(rawValue: 18)
        public static let sourceOut = BlendMode(rawValue: 19)
        public static let sourceAtop = BlendMode(rawValue: 20)
        public static let destinationOver = BlendMode(rawValue: 21)
        public static let destinationIn = BlendMode(rawValue: 22)
        public static let destinationOut = BlendMode(rawValue: 23)
        public static let destinationAtop = BlendMode(rawValue: 24)
        public static let xor = BlendMode(rawValue: 25)
        public static let plusDarker = BlendMode(rawValue: 26)
        public static let plusLighter = BlendMode(rawValue: 27)

        /// Porter-Duff modes have no rasteriser equivalent (09 §3.6) and
        /// composite normally.
        package var render: RenderBlendMode {
            let table: [RenderBlendMode] = [.normal, .multiply, .screen, .overlay, .darken, .lighten, .colorDodge, .colorBurn,
                                            .softLight, .hardLight, .difference, .exclusion, .hue, .saturation, .color, .luminosity]
            if rawValue >= 0 && Int(rawValue) < table.count { return table[Int(rawValue)] }
            return rawValue == 27 ? .plusLighter : .normal
        }
    }

    public struct ClipOptions: OptionSet, Sendable {
        public let rawValue: UInt32
        public init(rawValue: UInt32) { self.rawValue = rawValue }
        public static let inverse = ClipOptions(rawValue: 1)
    }

    public struct GradientOptions: OptionSet, Sendable {
        public let rawValue: UInt32
        public init(rawValue: UInt32) { self.rawValue = rawValue }
        public static let `repeat` = GradientOptions(rawValue: 1)
        public static let mirror = GradientOptions(rawValue: 2)
        public static let linearColor = GradientOptions(rawValue: 4)
        package var spread: RenderSpread { contains(.mirror) ? .reflect : contains(.repeat) ? .repeat : .pad }
    }

    public struct BlurOptions: OptionSet, Sendable {
        public let rawValue: UInt32
        public init(rawValue: UInt32) { self.rawValue = rawValue }
        public static let opaque = BlurOptions(rawValue: 1)
        public static let dithersResult = BlurOptions(rawValue: 2)
    }

    public struct FilterOptions: OptionSet, Sendable {
        public let rawValue: UInt32
        public init(rawValue: UInt32) { self.rawValue = rawValue }
        public static let linearColor = FilterOptions(rawValue: 1)
    }

    public struct ShadowOptions: OptionSet, Sendable {
        public let rawValue: UInt32
        public init(rawValue: UInt32) { self.rawValue = rawValue }
        public static let shadowAbove = ShadowOptions(rawValue: 1)
        public static let shadowOnly = ShadowOptions(rawValue: 2)
        public static let invertsAlpha = ShadowOptions(rawValue: 4)
        public static let disablesGroup = ShadowOptions(rawValue: 8)
    }

    /// A filter applied to everything drawn after it is added.
    public struct Filter: Sendable {
        package var effect: RenderEffect?
        package var multiply: RenderColor?

        public static func blur(radius: CGFloat, options: BlurOptions = BlurOptions()) -> Filter {
            Filter(effect: .blur(radius: Double(radius)))
        }
        public static func shadow(color: Color = Color(.sRGBLinear, white: 0, opacity: 0.33), radius: CGFloat, x: CGFloat = 0, y: CGFloat = 0,
                                  blendMode: BlendMode = .normal, options: ShadowOptions = ShadowOptions()) -> Filter {
            let c = color.resolve(in: EnvironmentValues()).renderColor
            return Filter(effect: .shadow(color: c, radius: Double(radius), x: Double(x), y: Double(y)))
        }
        public static func colorMultiply(_ color: Color) -> Filter {
            Filter(multiply: color.resolve(in: EnvironmentValues()).renderColor)
        }
        /// Filters without a rasteriser equivalent are accepted and ignored.
        public static func hueRotation(_ angle: Angle) -> Filter { Filter() }
        public static func saturation(_ amount: Double) -> Filter { Filter() }
        public static func brightness(_ amount: Double) -> Filter { Filter() }
        public static func contrast(_ amount: Double) -> Filter { Filter() }
        public static func grayscale(_ amount: Double) -> Filter { Filter() }
        public static var colorInvert: Filter { Filter() }
        public static func colorInvert(_ amount: Double = 1) -> Filter { Filter() }
        public static var luminanceToAlpha: Filter { Filter() }
    }

    /// How an area is painted.
    public struct Shading: Sendable {
        package enum Kind: Sendable {
            case style(AnyShapeStyle)
            case linear(Gradient, CGPoint, CGPoint, GradientOptions)
            case radial(Gradient, CGPoint, CGFloat, CGFloat, GradientOptions)
            case conic(Gradient, CGPoint, Angle)
        }
        package var kind: Kind

        public static var foreground: Shading { Shading(kind: .style(AnyShapeStyle(ForegroundStyle()))) }
        public static func color(_ color: Color) -> Shading { Shading(kind: .style(AnyShapeStyle(color))) }
        public static func color(_ colorSpace: Color.RGBColorSpace = .sRGB, red: Double, green: Double, blue: Double, opacity: Double = 1) -> Shading {
            .color(Color(colorSpace, red: red, green: green, blue: blue, opacity: opacity))
        }
        public static func color(_ colorSpace: Color.RGBColorSpace = .sRGB, white: Double, opacity: Double = 1) -> Shading {
            .color(Color(colorSpace, white: white, opacity: opacity))
        }
        public static func style<S: ShapeStyle>(_ style: S) -> Shading { Shading(kind: .style(AnyShapeStyle(style))) }
        public static func linearGradient(_ gradient: Gradient, startPoint: CGPoint, endPoint: CGPoint, options: GradientOptions = GradientOptions()) -> Shading {
            Shading(kind: .linear(gradient, startPoint, endPoint, options))
        }
        public static func radialGradient(_ gradient: Gradient, center: CGPoint, startRadius: CGFloat, endRadius: CGFloat,
                                          options: GradientOptions = GradientOptions()) -> Shading {
            Shading(kind: .radial(gradient, center, startRadius, endRadius, options))
        }
        public static func conicGradient(_ gradient: Gradient, center: CGPoint, angle: Angle = .zero, options: GradientOptions = GradientOptions()) -> Shading {
            Shading(kind: .conic(gradient, center, angle))
        }

        package func paint(bounds: CGRect, environment: EnvironmentValues) -> RenderPaint? {
            switch kind {
            case .style(let s):
                return resolvePaint(s.base, bounds: bounds, environment: environment)
            case let .linear(g, a, b, o):
                return .linearGradient(stops: g.renderStops(environment), start: a, end: b, spread: o.spread)
            case let .radial(g, c, r0, r1, o):
                return .radialGradient(stops: g.renderStops(environment), center: c, startRadius: Double(r0), endRadius: Double(r1), spread: o.spread)
            case let .conic(g, c, a):
                return .conicGradient(stops: g.renderStops(environment), center: c, startAngle: a.radians, endAngle: a.radians + 2 * .pi)
            }
        }
    }

    // MARK: State

    public mutating func translateBy(x: CGFloat, y: CGFloat) { transform = CGAffineTransform(translationX: x, y: y).concatenating(transform) }
    public mutating func scaleBy(x: CGFloat, y: CGFloat) { transform = CGAffineTransform(scaleX: x, y: y).concatenating(transform) }
    public mutating func rotate(by angle: Angle) { transform = CGAffineTransform(rotationAngle: CGFloat(angle.radians)).concatenating(transform) }
    public mutating func concatenate(_ matrix: CGAffineTransform) { transform = matrix.concatenating(transform) }

    /// Intersects the clip with `path` (in the current coordinates).
    public mutating func clip(to path: Path, style: FillStyle = FillStyle(), options: ClipOptions = ClipOptions()) {
        clips.append(RenderClip(path: path.applying(transform).renderPath, fillRule: style.isEOFilled ? .evenOdd : .nonZero,
                                inverse: options.contains(.inverse)))
    }

    /// The bounding box of the current clip in the current coordinates.
    public var clipBoundingRect: CGRect {
        var r = CGRect(origin: .zero, size: size)
        for c in clips where !c.inverse { r = r.intersection(c.path.controlBounds) }
        return r.applying(transform.inverted())
    }

    public mutating func addFilter(_ filter: Filter, options: FilterOptions = FilterOptions()) {
        if let e = filter.effect { effects.append(e) }
        if let m = filter.multiply { multiplyColor = (multiplyColor ?? .white).multiplied(by: m) }
    }

    package var multiplyColor: RenderColor?

    // MARK: Drawing

    /// Appends contents drawn in the current coordinates.
    private func emit(_ contents: [DisplayItem.Content]) {
        guard !contents.isEmpty, opacity > 0 else { return }
        var items = contents.map { DisplayItem(id: recording.nextID(), $0) }
        if let m = multiplyColor { items = items.map { $0.multiplyingColors(by: m) } }
        let t = transform.renderTransform
        if !t.isIdentity {
            if t.a == 1 && t.b == 0 && t.c == 0 && t.d == 1 {
                items = items.map { $0.translated(t.tx, t.ty) }
            } else {
                items = [DisplayItem(id: recording.nextID(), .group(DisplayGroup(transform: t, children: items)))]
            }
        }
        if opacity < 1 || blendMode != .normal || !clips.isEmpty || !effects.isEmpty {
            items = [DisplayItem(id: recording.nextID(), .group(DisplayGroup(opacity: opacity, blendMode: blendMode.render, clips: clips,
                                                                            effects: effects, children: items)))]
        }
        recording.items.append(contentsOf: items)
    }

    public func fill(_ path: Path, with shading: Shading, style: FillStyle = FillStyle()) {
        guard let paint = shading.paint(bounds: path.boundingRect, environment: environment) else { return }
        emit([.fill(path.renderPath, paint, style.isEOFilled ? .evenOdd : .nonZero)])
    }

    public func stroke(_ path: Path, with shading: Shading, style: StrokeStyle) {
        guard let paint = shading.paint(bounds: path.boundingRect, environment: environment) else { return }
        emit([.stroke(path.renderPath, paint, style.renderStroke)])
    }

    public func stroke(_ path: Path, with shading: Shading, lineWidth: CGFloat = 1) {
        stroke(path, with: shading, style: StrokeStyle(lineWidth: lineWidth))
    }

    /// An image resolved in this context's environment.
    public struct ResolvedImage {
        package let image: Image
        public let size: CGSize
        public var baseline: CGFloat
        public var shading: Shading?
    }

    public func resolve(_ image: Image) -> ResolvedImage {
        var size = CGSize.zero, baseline: CGFloat = 0
        switch image.source {
        case .system(let name):
            let font = (environment.font ?? .body).textFont(in: environment)
            if let m = OpenSymbolProvider.shared.symbol(named: name, font: font) {
                size = m.size
                baseline = m.size.height - m.baselineOffset
            }
        case let .named(name, bundle):
            size = ImageAssets.lookup(name, bundle: bundle?.bundle, displayScale: environment.displayScale)?.pointSize ?? .zero
            baseline = size.height
        case let .raster(img, scale):
            size = CGSize(width: CGFloat(img.pixelSize.width) / scale, height: CGFloat(img.pixelSize.height) / scale)
            baseline = size.height
        case .natural(let s):
            size = s
        }
        return ResolvedImage(image: image, size: size, baseline: baseline, shading: nil)
    }

    public func draw(_ image: ResolvedImage, in rect: CGRect, style: FillStyle = FillStyle()) {
        var env = environment
        if let s = image.shading, case .style(let st) = s.kind { env.foregroundStyle = st }
        let draw = image.image.resizable().draw(environment: env, symbols: nil)
        var rec = DrawRecorder(id: recording.nextID())
        draw(&rec, rect.size)
        emit(rec.items.map { $0.translated(Double(rect.minX), Double(rect.minY)).content })
    }

    public func draw(_ image: ResolvedImage, at point: CGPoint, anchor: UnitPoint = .center) {
        let o = CGPoint(x: point.x - anchor.x * image.size.width, y: point.y - anchor.y * image.size.height)
        draw(image, in: CGRect(origin: o, size: image.size))
    }

    public func draw(_ image: Image, in rect: CGRect, style: FillStyle = FillStyle()) { draw(resolve(image), in: rect, style: style) }

    public func draw(_ image: Image, at point: CGPoint, anchor: UnitPoint = .center) { draw(resolve(image), at: point, anchor: anchor) }

    /// A text resolved in this context's environment.
    public struct ResolvedText {
        package let text: OpenViewsResolvedText
        package let environment: EnvironmentValues
        public var shading: Shading = .foreground

        public func measure(in size: CGSize) -> CGSize {
            TypesetTextMeasurer.shared.measure(text, proposal: ProposedViewSize(size)).size
        }
        public func firstBaseline(in size: CGSize) -> CGFloat {
            TypesetTextMeasurer.shared.measure(text, proposal: ProposedViewSize(size)).firstBaseline ?? 0
        }
        public func lastBaseline(in size: CGSize) -> CGFloat {
            TypesetTextMeasurer.shared.measure(text, proposal: ProposedViewSize(size)).lastBaseline ?? 0
        }
    }

    public func resolve(_ text: Text) -> ResolvedText {
        ResolvedText(text: text.resolve(in: environment), environment: environment)
    }

    public func draw(_ text: ResolvedText, in rect: CGRect) {
        var env = text.environment
        // (The default `.foreground` shading keeps the environment's style:
        // making the foreground style the foreground style recursed forever.)
        if case .style(let s) = text.shading.kind, !(s.base is ForegroundStyle) { env.foregroundStyle = s }
        var rec = DrawRecorder(id: recording.nextID(), textMeasurer: TypesetTextMeasurer.shared)
        let size = text.measure(in: rect.size)
        textDraw(text.text, environment: env)(&rec, CGSize(width: min(size.width, rect.width), height: min(size.height, rect.height)))
        emit(rec.items.map { $0.translated(Double(rect.minX), Double(rect.minY)).content })
    }

    public func draw(_ text: ResolvedText, at point: CGPoint, anchor: UnitPoint = .center) {
        let size = text.measure(in: CGSize(width: CGFloat.infinity, height: .infinity))
        draw(text, in: CGRect(x: point.x - anchor.x * size.width, y: point.y - anchor.y * size.height, width: size.width, height: size.height))
    }

    public func draw(_ text: Text, in rect: CGRect) { draw(resolve(text), in: rect) }

    public func draw(_ text: Text, at point: CGPoint, anchor: UnitPoint = .center) { draw(resolve(text), at: point, anchor: anchor) }

    /// Draws into a new layer: `content` draws with this context's transform
    /// and clips; the layer is composited with this context's opacity,
    /// blend mode and filters.
    public func drawLayer(content: (inout GraphicsContext) throws -> Void) rethrows {
        let layer = GraphicsRecording(id: recording.nextID())
        var inner = self
        inner.recording = layer
        inner.opacity = 1
        inner.blendMode = .normal
        inner.effects = []
        inner.clips = []
        try content(&inner)
        guard !layer.items.isEmpty, opacity > 0 else { return }
        var items = layer.items
        if opacity < 1 || blendMode != .normal || !clips.isEmpty || !effects.isEmpty {
            items = [DisplayItem(id: recording.nextID(), .group(DisplayGroup(opacity: opacity, blendMode: blendMode.render, clips: clips,
                                                                            effects: effects, children: items)))]
        }
        recording.items.append(contentsOf: items)
    }

    /// Appends display items recorded elsewhere (ImageRenderer).
    package mutating func append(_ list: DisplayList) {
        let saved = (opacity, blendMode)
        emit(list.items.map(\.content))
        (opacity, blendMode) = saved
    }
}

package typealias OpenViewsResolvedText = ResolvedText

/// A view that draws with a graphics context.
public struct Canvas<Symbols: View>: View {
    package var renderer: (inout GraphicsContext, CGSize) -> Void
    package var isOpaque: Bool
    package var rendersAsynchronously: Bool
    public typealias Body = Never
}

extension Canvas where Symbols == EmptyView {
    public init(opaque: Bool = false, colorMode: ColorRenderingMode = .nonLinear, rendersAsynchronously: Bool = false,
                renderer: @escaping (inout GraphicsContext, CGSize) -> Void) {
        self.renderer = renderer
        isOpaque = opaque
        self.rendersAsynchronously = rendersAsynchronously
    }
}

extension Canvas: PrimitiveView {
    package func _makeChildren(node: ViewNode, old: Canvas?, transaction: Transaction) {}

    package func _lower(node: ViewNode) -> [LayoutNode] {
        let n = LayoutNode(ShapeViewLeaf(fits: { $0.replacingUnspecifiedDimensions() }))
        let renderer = self.renderer
        let env = node.environment
        n.draw = { rec, size in
            let recording = GraphicsRecording(id: rec.nextID())
            var ctx = GraphicsContext(recording: recording, environment: env, size: size)
            renderer(&ctx, size)
            // Canvas content is not mirrored for right-to-left layout.
            rec.addUnmirrored(width: size.width, recording.items.map(\.content))
        }
        return [n]
    }
}
