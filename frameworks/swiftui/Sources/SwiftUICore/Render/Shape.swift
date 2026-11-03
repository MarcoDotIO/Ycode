import Foundation
import OVRender

// Shapes (round R5): the `Shape` protocol, the built-in shapes, fill and
// stroke styles, and the views shapes become. A shape used as a view fills
// itself with the foreground style; `fill`, `stroke` and `strokeBorder`
// choose the style. Layout follows 04 §2 (shapes take the proposal, nil →
// 10; `Circle` answers a square).

/// How a path is filled.
public struct FillStyle: Equatable, Sendable {
    public var isEOFilled: Bool
    public var isAntialiased: Bool
    public init(eoFill: Bool = false, antialiased: Bool = true) {
        isEOFilled = eoFill
        isAntialiased = antialiased
    }
}

/// How a path is stroked.
public struct StrokeStyle: Equatable, Sendable {
    public var lineWidth: CGFloat
    public var lineCap: CGLineCap
    public var lineJoin: CGLineJoin
    public var miterLimit: CGFloat
    public var dash: [CGFloat]
    public var dashPhase: CGFloat
    public init(lineWidth: CGFloat = 1, lineCap: CGLineCap = .butt, lineJoin: CGLineJoin = .miter, miterLimit: CGFloat = 10,
                dash: [CGFloat] = [], dashPhase: CGFloat = 0) {
        self.lineWidth = lineWidth
        self.lineCap = lineCap
        self.lineJoin = lineJoin
        self.miterLimit = miterLimit
        self.dash = dash
        self.dashPhase = dashPhase
    }

    package var renderStroke: RenderStroke {
        RenderStroke(lineWidth: Double(lineWidth),
                     lineCap: lineCap == .round ? .round : lineCap == .square ? .square : .butt,
                     lineJoin: lineJoin == .round ? .round : lineJoin == .bevel ? .bevel : .miter,
                     miterLimit: Double(miterLimit), dash: dash.map { Double($0) }, dashPhase: Double(dashPhase))
    }
}

extension StrokeStyle: Animatable {
    public var animatableData: AnimatablePair<CGFloat, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(lineWidth, AnimatablePair(miterLimit, dashPhase)) }
        set {
            lineWidth = newValue.first
            miterLimit = newValue.second.first
            dashPhase = newValue.second.second
        }
    }
}

#if !canImport(CoreGraphics)
/// Line cap styles (CoreGraphics names).
public enum CGLineCap: Int32, Sendable {
    case butt, round, square
}

/// Line join styles (CoreGraphics names).
public enum CGLineJoin: Int32, Sendable {
    case miter, round, bevel
}
#endif

/// What a shape is used for.
public enum ShapeRole: Hashable, Sendable {
    case fill, stroke, separator
}

/// A 2-D shape: a path in a rectangle.
public protocol Shape: Sendable, Animatable, View {
    nonisolated func path(in rect: CGRect) -> Path
    /// The size the shape takes for a proposal (default: the proposal, nil
    /// dimensions → 10).
    nonisolated func sizeThatFits(_ proposal: ProposedViewSize) -> CGSize
    nonisolated static var role: ShapeRole { get }
}

extension Shape {
    nonisolated public func sizeThatFits(_ proposal: ProposedViewSize) -> CGSize { proposal.replacingUnspecifiedDimensions() }
    nonisolated public static var role: ShapeRole { .fill }
}

extension Shape {
    /// A shape used as a view fills itself with the foreground style.
    public var body: _ShapeView<Self, ForegroundStyle> { _ShapeView(shape: self, style: ForegroundStyle()) }
}

/// A shape that can be inset (and stroked inside its bounds).
public protocol InsettableShape: Shape {
    associatedtype InsetShape: InsettableShape
    nonisolated func inset(by amount: CGFloat) -> InsetShape
}

/// How a shape view paints its shape.
package enum ShapeDrawMode: Equatable, Sendable {
    case fill(FillStyle)
    case stroke(StrokeStyle)
}

/// A shape drawn with a style: the view `fill`, `stroke` and a bare shape
/// produce.
/// Views that draw only an outline: they take no hits (QA B2: a border or
/// a stroked overlay blocked the taps of the views below it) unless a
/// `contentShape` says otherwise.
@MainActor package protocol StrokeOnlyDrawing {
    var _drawsOnlyStroke: Bool { get }
}

extension _ShapeView: StrokeOnlyDrawing {
    package var _drawsOnlyStroke: Bool {
        if case .stroke = mode { return true }
        return false
    }
}

public struct _ShapeView<Content: Shape, Style: ShapeStyle>: View {
    public var shape: Content
    public var style: Style
    package var mode: ShapeDrawMode
    public init(shape: Content, style: Style, fillStyle: FillStyle = FillStyle()) {
        self.shape = shape
        self.style = style
        mode = .fill(fillStyle)
    }
    package init(shape: Content, style: Style, mode: ShapeDrawMode) {
        self.shape = shape
        self.style = style
        self.mode = mode
    }
    public typealias Body = Never
}

extension _ShapeView: PrimitiveView {
    package func _makeChildren(node: ViewNode, old: _ShapeView?, transaction: Transaction) {}

    package func _lower(node: ViewNode) -> [LayoutNode] {
        let shape = self.shape
        let n = LayoutNode(ShapeViewLeaf(fits: { shape.sizeThatFits($0) }))
        n.draw = shapeDraw(shape: shape, style: style, mode: mode, environment: node.environment)
        return [n]
    }
}

/// The drawing of a shape view: the path in the node's bounds, filled or
/// stroked with the style resolved for those bounds.
package func shapeDraw<S: Shape>(shape: S, style: any ShapeStyle, mode: ShapeDrawMode, environment: EnvironmentValues) -> NodeDraw {
    { rec, size in
        let rect = CGRect(origin: .zero, size: size)
        let path = shape.path(in: rect).renderPath
        guard !path.isEmpty, let paint = resolvePaint(style, bounds: rect, environment: environment) else { return }
        switch mode {
        case .fill(let fs): rec.add(.fill(path, paint, fs.isEOFilled ? .evenOdd : .nonZero))
        case .stroke(let st): rec.add(.stroke(path, paint, st.renderStroke))
        }
    }
}

/// A shape view's layout: the shape's own `sizeThatFits`.
package struct ShapeViewLeaf: NodeBehavior {
    let fits: (ProposedViewSize) -> CGSize
    nonisolated package func sizeThatFits(_ p: ProposedViewSize, node: LayoutNode) -> CGSize { fits(p) }
}

extension Shape {
    public func fill<S: ShapeStyle>(_ content: S, style: FillStyle = FillStyle()) -> _ShapeView<Self, S> {
        _ShapeView(shape: self, style: content, fillStyle: style)
    }

    public func fill(style: FillStyle = FillStyle()) -> _ShapeView<Self, ForegroundStyle> {
        _ShapeView(shape: self, style: ForegroundStyle(), fillStyle: style)
    }

    public func stroke<S: ShapeStyle>(_ content: S, style: StrokeStyle, antialiased: Bool = true) -> _ShapeView<Self, S> {
        _ShapeView(shape: self, style: content, mode: .stroke(style))
    }

    public func stroke<S: ShapeStyle>(_ content: S, lineWidth: CGFloat = 1, antialiased: Bool = true) -> _ShapeView<Self, S> {
        stroke(content, style: StrokeStyle(lineWidth: lineWidth))
    }

    public func stroke(style: StrokeStyle) -> _ShapeView<Self, ForegroundStyle> {
        _ShapeView(shape: self, style: ForegroundStyle(), mode: .stroke(style))
    }

    public func stroke(lineWidth: CGFloat = 1) -> _ShapeView<Self, ForegroundStyle> { stroke(style: StrokeStyle(lineWidth: lineWidth)) }

    /// The part of the outline between fractions `from` and `to` of its
    /// length.
    public func trim(from startFraction: CGFloat = 0, to endFraction: CGFloat = 1) -> some Shape {
        _TrimmedShape(shape: self, startFraction: startFraction, endFraction: endFraction)
    }

    public func offset(x: CGFloat = 0, y: CGFloat = 0) -> some Shape {
        TransformedShape(shape: self, transform: CGAffineTransform(translationX: x, y: y))
    }

    public func offset(_ offset: CGSize) -> some Shape { self.offset(x: offset.width, y: offset.height) }

    public func scale(x: CGFloat = 1, y: CGFloat = 1, anchor: UnitPoint = .center) -> some Shape {
        _AnchoredShape(shape: self) { rect in
            let a = anchor.point(in: rect)
            return CGAffineTransform(translationX: -a.x, y: -a.y).concatenating(CGAffineTransform(scaleX: x, y: y))
                .concatenating(CGAffineTransform(translationX: a.x, y: a.y))
        }
    }

    public func scale(_ scale: CGFloat, anchor: UnitPoint = .center) -> some Shape { self.scale(x: scale, y: scale, anchor: anchor) }

    public func rotation(_ angle: Angle, anchor: UnitPoint = .center) -> some Shape {
        _AnchoredShape(shape: self) { rect in
            let a = anchor.point(in: rect)
            return CGAffineTransform(translationX: -a.x, y: -a.y).concatenating(CGAffineTransform(rotationAngle: CGFloat(angle.radians)))
                .concatenating(CGAffineTransform(translationX: a.x, y: a.y))
        }
    }

    public func transform(_ transform: CGAffineTransform) -> TransformedShape<Self> { TransformedShape(shape: self, transform: transform) }
}

extension InsettableShape {
    public func strokeBorder<S: ShapeStyle>(_ content: S, style: StrokeStyle, antialiased: Bool = true) -> some View {
        inset(by: style.lineWidth / 2).stroke(content, style: style)
    }

    public func strokeBorder(style: StrokeStyle, antialiased: Bool = true) -> some View {
        inset(by: style.lineWidth / 2).stroke(style: style)
    }

    public func strokeBorder<S: ShapeStyle>(_ content: S, lineWidth: CGFloat = 1, antialiased: Bool = true) -> some View {
        strokeBorder(content, style: StrokeStyle(lineWidth: lineWidth))
    }

    public func strokeBorder(lineWidth: CGFloat = 1, antialiased: Bool = true) -> some View {
        strokeBorder(style: StrokeStyle(lineWidth: lineWidth))
    }
}

package struct _TrimmedShape<S: Shape>: Shape {
    var shape: S
    var startFraction: CGFloat
    var endFraction: CGFloat
    nonisolated package func path(in rect: CGRect) -> Path { shape.path(in: rect).trimmedPath(from: startFraction, to: endFraction) }
    nonisolated package func sizeThatFits(_ proposal: ProposedViewSize) -> CGSize { shape.sizeThatFits(proposal) }
    nonisolated package var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(startFraction, endFraction) }
        set {
            startFraction = newValue.first
            endFraction = newValue.second
        }
    }
}

package struct _AnchoredShape<S: Shape>: Shape {
    var shape: S
    let transform: @Sendable (CGRect) -> CGAffineTransform
    nonisolated package func path(in rect: CGRect) -> Path { shape.path(in: rect).applying(transform(rect)) }
    nonisolated package func sizeThatFits(_ proposal: ProposedViewSize) -> CGSize { shape.sizeThatFits(proposal) }
}

/// A shape with an affine transform applied to its path.
public struct TransformedShape<Content: Shape>: Shape {
    public var shape: Content
    public var transform: CGAffineTransform
    public init(shape: Content, transform: CGAffineTransform) {
        self.shape = shape
        self.transform = transform
    }
    nonisolated public func path(in rect: CGRect) -> Path { shape.path(in: rect).applying(transform) }
    nonisolated public func sizeThatFits(_ proposal: ProposedViewSize) -> CGSize { shape.sizeThatFits(proposal) }
}

/// A type-erased shape.
public struct AnyShape: Shape {
    private let pathIn: @Sendable (CGRect) -> Path
    private let fits: @Sendable (ProposedViewSize) -> CGSize
    public init<S: Shape>(_ shape: S) {
        pathIn = { shape.path(in: $0) }
        fits = { shape.sizeThatFits($0) }
    }
    nonisolated public func path(in rect: CGRect) -> Path { pathIn(rect) }
    nonisolated public func sizeThatFits(_ proposal: ProposedViewSize) -> CGSize { fits(proposal) }
}

extension Path: Shape {
    nonisolated public func path(in rect: CGRect) -> Path { self }
}

// MARK: - Built-in shapes

/// A rectangle filling its bounds.
public struct Rectangle: InsettableShape {
    package var insetAmount: CGFloat = 0
    public init() {}
    nonisolated public func path(in rect: CGRect) -> Path { Path(rect.insetBy(dx: insetAmount, dy: insetAmount)) }
    nonisolated public func inset(by amount: CGFloat) -> Rectangle {
        var r = self
        r.insetAmount += amount
        return r
    }
}

/// A rectangle with rounded corners.
public struct RoundedRectangle: InsettableShape {
    public var cornerSize: CGSize
    public var style: RoundedCornerStyle
    package var insetAmount: CGFloat = 0
    public init(cornerSize: CGSize, style: RoundedCornerStyle = .continuous) {
        self.cornerSize = cornerSize
        self.style = style
    }
    public init(cornerRadius: CGFloat, style: RoundedCornerStyle = .continuous) {
        self.init(cornerSize: CGSize(width: cornerRadius, height: cornerRadius), style: style)
    }
    nonisolated public func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: insetAmount, dy: insetAmount)
        let c = CGSize(width: max(0, cornerSize.width - insetAmount), height: max(0, cornerSize.height - insetAmount))
        return Path(roundedRect: r, cornerSize: c, style: style)
    }
    nonisolated public func inset(by amount: CGFloat) -> RoundedRectangle {
        var r = self
        r.insetAmount += amount
        return r
    }
    nonisolated public var animatableData: CGSize.AnimatableData {
        get { cornerSize.animatableData }
        set { cornerSize.animatableData = newValue }
    }
}

/// A rectangle with a radius per corner.
public struct UnevenRoundedRectangle: InsettableShape {
    public var cornerRadii: RectangleCornerRadii
    public var style: RoundedCornerStyle
    package var insetAmount: CGFloat = 0
    public init(cornerRadii: RectangleCornerRadii, style: RoundedCornerStyle = .continuous) {
        self.cornerRadii = cornerRadii
        self.style = style
    }
    public init(topLeadingRadius: CGFloat = 0, bottomLeadingRadius: CGFloat = 0, bottomTrailingRadius: CGFloat = 0,
                topTrailingRadius: CGFloat = 0, style: RoundedCornerStyle = .continuous) {
        self.init(cornerRadii: RectangleCornerRadii(topLeading: topLeadingRadius, bottomLeading: bottomLeadingRadius,
                                                    bottomTrailing: bottomTrailingRadius, topTrailing: topTrailingRadius), style: style)
    }
    nonisolated public func path(in rect: CGRect) -> Path {
        let i = insetAmount
        let c = RectangleCornerRadii(topLeading: max(0, cornerRadii.topLeading - i), bottomLeading: max(0, cornerRadii.bottomLeading - i),
                                     bottomTrailing: max(0, cornerRadii.bottomTrailing - i), topTrailing: max(0, cornerRadii.topTrailing - i))
        return Path(roundedRect: rect.insetBy(dx: i, dy: i), cornerRadii: c, style: style)
    }
    nonisolated public func inset(by amount: CGFloat) -> UnevenRoundedRectangle {
        var r = self
        r.insetAmount += amount
        return r
    }
}

/// A rounded rectangle whose corner radius is half its shorter side.
public struct Capsule: InsettableShape {
    public var style: RoundedCornerStyle
    package var insetAmount: CGFloat = 0
    public init(style: RoundedCornerStyle = .continuous) { self.style = style }
    nonisolated public func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: insetAmount, dy: insetAmount)
        let radius = min(r.width, r.height) / 2
        // A capsule's ends are semicircles in either corner style.
        return Path(roundedRect: r, cornerRadius: radius, style: .circular)
    }
    nonisolated public func inset(by amount: CGFloat) -> Capsule {
        var r = self
        r.insetAmount += amount
        return r
    }
}

/// An ellipse filling its bounds.
public struct Ellipse: InsettableShape {
    package var insetAmount: CGFloat = 0
    public init() {}
    nonisolated public func path(in rect: CGRect) -> Path { Path(ellipseIn: rect.insetBy(dx: insetAmount, dy: insetAmount)) }
    nonisolated public func inset(by amount: CGFloat) -> Ellipse {
        var r = self
        r.insetAmount += amount
        return r
    }
}

/// A circle centred in its bounds, as large as the shorter side.
public struct Circle: InsettableShape {
    package var insetAmount: CGFloat = 0
    public init() {}
    nonisolated public func path(in rect: CGRect) -> Path {
        let d = min(rect.width, rect.height) - 2 * insetAmount
        guard d > 0 else { return Path() }
        return Path(ellipseIn: CGRect(x: rect.midX - d / 2, y: rect.midY - d / 2, width: d, height: d))
    }
    /// A square of the smaller proposed dimension; one nil → the other; both
    /// nil → 10 × 10 (04 §2; golden `circle`).
    nonisolated public func sizeThatFits(_ p: ProposedViewSize) -> CGSize {
        switch (p.width, p.height) {
        case (nil, nil): return CGSize(width: 10, height: 10)
        case (let w?, nil): return CGSize(width: w, height: w)
        case (nil, let h?): return CGSize(width: h, height: h)
        case (let w?, let h?):
            let s = min(w, h)
            return CGSize(width: s, height: s)
        }
    }
    nonisolated public func inset(by amount: CGFloat) -> Circle {
        var r = self
        r.insetAmount += amount
        return r
    }
}

extension Shape where Self == Rectangle {
    public static var rect: Rectangle { Rectangle() }
}

extension Shape where Self == RoundedRectangle {
    public static func rect(cornerRadius: CGFloat, style: RoundedCornerStyle = .continuous) -> RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: style)
    }
    public static func rect(cornerSize: CGSize, style: RoundedCornerStyle = .continuous) -> RoundedRectangle {
        RoundedRectangle(cornerSize: cornerSize, style: style)
    }
}

extension Shape where Self == UnevenRoundedRectangle {
    public static func rect(cornerRadii: RectangleCornerRadii, style: RoundedCornerStyle = .continuous) -> UnevenRoundedRectangle {
        UnevenRoundedRectangle(cornerRadii: cornerRadii, style: style)
    }
    public static func rect(topLeadingRadius: CGFloat = 0, bottomLeadingRadius: CGFloat = 0, bottomTrailingRadius: CGFloat = 0,
                            topTrailingRadius: CGFloat = 0, style: RoundedCornerStyle = .continuous) -> UnevenRoundedRectangle {
        UnevenRoundedRectangle(topLeadingRadius: topLeadingRadius, bottomLeadingRadius: bottomLeadingRadius,
                               bottomTrailingRadius: bottomTrailingRadius, topTrailingRadius: topTrailingRadius, style: style)
    }
}

extension Shape where Self == Capsule {
    public static var capsule: Capsule { Capsule() }
    public static func capsule(style: RoundedCornerStyle) -> Capsule { Capsule(style: style) }
}

extension Shape where Self == Ellipse {
    public static var ellipse: Ellipse { Ellipse() }
}

extension Shape where Self == Circle {
    public static var circle: Circle { Circle() }
}
