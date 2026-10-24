import Foundation

// OpenViews layout engine (09-open-design.md §3.3), round R3.
//
// The engine is a pure function of a small tree of layout nodes: each node
// has a *behaviour* (a leaf such as a colour or a text, a modifier such as a
// frame or padding, or a container such as a stack) and children. Layout is
// the negotiation of 04-layout.md §1: a parent proposes, the child answers,
// the parent places. Answers are memoised per proposal (they must be pure,
// 04 §8). Round R2's views will build these trees; until then tests build
// them directly (package API in NodeBuilders.swift).

/// Where a behaviour puts one of its children, in the node's own coordinates.
package struct ChildPlacement {
    package var index: Int
    package var origin: CGPoint
    package var size: CGSize
    package var proposal: ProposedViewSize

    package init(index: Int, origin: CGPoint, size: CGSize, proposal: ProposedViewSize) {
        self.index = index
        self.origin = origin
        self.size = size
        self.proposal = proposal
    }
}

/// How one kind of node measures itself and places its children.
package protocol NodeBehavior {
    /// The stack orientation child `index` sees (04 §2: `Spacer` and `Divider`
    /// orient themselves by the enclosing stack). Default: a modifier passes
    /// the inherited orientation to its trait child and nil to the others.
    func childStackOrientation(inherited: Axis?, child index: Int) -> Axis?
    func sizeThatFits(_ proposal: ProposedViewSize, node: LayoutNode) -> CGSize
    /// Children placements for a node of `size` placed with `proposal`.
    func placeChildren(size: CGSize, proposal: ProposedViewSize, node: LayoutNode) -> [ChildPlacement]
    /// The node's explicit value for `key` (nil = use the guide's default).
    func explicitAlignment(_ key: AlignmentKey, size: CGSize, proposal: ProposedViewSize, node: LayoutNode) -> CGFloat?
    func spacing(node: LayoutNode) -> ViewSpacing
    func layoutPriority(node: LayoutNode) -> Double
    func layoutValue(_ key: ObjectIdentifier, node: LayoutNode) -> Any?
    /// A render transform applied to the children (offset, scale, rotation);
    /// it never changes layout (04 §5), only reported frames.
    func childTransform(size: CGSize) -> AffineTransform2D?
    /// The child whose spacing, priority, layout values and explicit guides
    /// pass through this node unchanged (modifiers); nil for leaves and
    /// containers.
    var traitChild: Int? { get }
    /// True for `EmptyView`: containers leave such children out entirely.
    var isEmpty: Bool { get }
}

extension NodeBehavior {
    package var traitChild: Int? { nil }
    package var isEmpty: Bool { false }

    package func childStackOrientation(inherited: Axis?, child index: Int) -> Axis? {
        traitChild == index ? inherited : nil
    }

    package func placeChildren(size: CGSize, proposal: ProposedViewSize, node: LayoutNode) -> [ChildPlacement] { [] }

    package func explicitAlignment(_ key: AlignmentKey, size: CGSize, proposal: ProposedViewSize,
                                   node: LayoutNode) -> CGFloat? {
        guard let i = traitChild else { return nil }
        return node.childExplicitAlignment(key, child: i, size: size, proposal: proposal)
    }

    package func spacing(node: LayoutNode) -> ViewSpacing {
        traitChild.map { node.children[$0].spacing } ?? ViewSpacing()
    }

    package func layoutPriority(node: LayoutNode) -> Double {
        traitChild.map { node.children[$0].layoutPriority } ?? 0
    }

    package func layoutValue(_ key: ObjectIdentifier, node: LayoutNode) -> Any? {
        traitChild.flatMap { node.children[$0].layoutValue(key) }
    }

    package func childTransform(size: CGSize) -> AffineTransform2D? { nil }
}

/// Shared state of one layout pass: environment, text and symbol measurement,
/// safe area, and a counter of answers that depended on measurements the
/// current text/symbol back end could not make exactly.
package final class LayoutContext {
    package var environment: EnvironmentValues
    package var textMeasurer: any TextMeasurer
    package var symbols: any SymbolProvider
    /// Window and safe rectangles (root coordinates), when laid out as a window.
    package var safeArea: (window: CGRect, safe: CGRect)?
    package private(set) var uncertainCount = 0
    /// Dimensions the current measurement actually uses (see `measuring`).
    private var interest: Axis.Set = [.horizontal, .vertical]
    /// Unknown dimensions reported while the innermost node was measured.
    fileprivate var unknownAccumulator: Axis.Set = []

    package init(environment: EnvironmentValues = EnvironmentValues(),
                 textMeasurer: any TextMeasurer = TypesetTextMeasurer.shared,
                 symbols: any SymbolProvider = StubSymbolProvider()) {
        self.environment = environment
        self.textMeasurer = textMeasurer
        self.symbols = symbols
    }

    /// Records that the dimensions `axes` of an answer are approximate (e.g.
    /// a text that would need line breaking, which arrives with the text
    /// round R4). The pass counts as uncertain only if a dimension the
    /// current measurement uses is affected.
    package func uncertain(_ axes: Axis.Set) {
        guard !axes.isEmpty else { return }
        unknownAccumulator.formUnion(axes)
        if !axes.intersection(interest).isEmpty { uncertainCount += 1 }
    }

    /// Runs a measurement whose result is only used along `axis` (a stack's
    /// minimum/maximum/offer lengths, a grid's column widths): unknown
    /// dimensions across it do not make the pass uncertain. Cached answers
    /// remember their unknown dimensions, so a later use of the other
    /// dimension still counts.
    package func measuring<R>(_ axis: Axis, _ body: () -> R) -> R {
        let saved = interest, outer = unknownAccumulator
        interest = Axis.Set(axis)
        unknownAccumulator = []
        let r = body()
        // Only the measured dimension feeds the caller's answer.
        unknownAccumulator = outer.union(unknownAccumulator.intersection(Axis.Set(axis)))
        interest = saved
        return r
    }
}

/// A node of the layout tree.
package final class LayoutNode {
    package let behavior: any NodeBehavior
    package private(set) var children: [LayoutNode]
    /// Frames of named nodes are reported in `LayoutResult`.
    package var name: String?
    package private(set) var stackOrientation: Axis?
    package private(set) var context: LayoutContext!

    /// Per-node storage for `Layout` caches.
    package var layoutCache: Any?

    /// The view-graph node this layout node was lowered from, when that node
    /// wants its geometry reported (geometry readers, geometry observers).
    package weak var owner: AnyObject?

    /// The view-graph node whose lowering created this node, and the
    /// node's index among the nodes it created (stable across passes): the
    /// key of the node's geometry animation (R6).
    package weak var creator: AnyObject?
    package var creatorIndex = 0

    /// How rendering differs from layout for this node's children (render
    /// effects whose values animate, R6). Read on the main actor.
    package var presentation: PresentationEffect?

    private var sizes: [ProposalKey: (size: CGSize, unknown: Axis.Set)] = [:]
    private var dims: [ProposalKey: ViewDimensions] = [:]
    private var placementMemo: [PlacementKey: [ChildPlacement]] = [:]

    // Results of the last placement pass (root coordinates).
    package private(set) var placedFrame: CGRect?
    package private(set) var placedSize: CGSize?
    package private(set) var placedProposal: ProposedViewSize?
    package private(set) var placedTransform: AffineTransform2D?
    /// Origin of the last placement in the parent's coordinates.
    package private(set) var placedLocalOrigin: CGPoint?

    package init(_ behavior: any NodeBehavior, children: [LayoutNode] = [], name: String? = nil) {
        self.behavior = behavior
        self.children = children
        self.name = name
    }

    /// Children that take part in layout (`EmptyView` children are dropped).
    package var layoutChildren: [LayoutNode] { children.filter { !$0.behavior.isEmpty } }

    // MARK: Preparation

    /// Attaches the context, resolves stack orientations and clears caches.
    package func prepare(context: LayoutContext, stackOrientation: Axis? = nil) {
        self.context = context
        self.stackOrientation = stackOrientation
        sizes = [:]
        dims = [:]
        placementMemo = [:]
        layoutCache = nil
        placedFrame = nil
        placedSize = nil
        placedProposal = nil
        placedTransform = nil
        placedLocalOrigin = nil
        for (i, c) in children.enumerated() {
            c.prepare(context: context,
                      stackOrientation: behavior.childStackOrientation(inherited: stackOrientation, child: i))
        }
    }

    // MARK: Measuring

    /// The size this node answers for `proposal` (memoised).
    package func sizeThatFits(_ proposal: ProposedViewSize) -> CGSize {
        let key = ProposalKey(proposal)
        if let s = sizes[key] {
            context.uncertain(s.unknown)
            return s.size
        }
        let outer = context.unknownAccumulator
        context.unknownAccumulator = []
        let s = behavior.sizeThatFits(proposal, node: self)
        let unknown = context.unknownAccumulator
        sizes[key] = (s, unknown)
        context.unknownAccumulator = outer.union(unknown)
        return s
    }

    /// The answer's length along `axis` only (see `LayoutContext.measuring`).
    package func length(along axis: Axis, _ proposal: ProposedViewSize) -> CGFloat {
        context.measuring(axis) { sizeThatFits(proposal)[axis] }
    }

    /// Size and alignment guides for `proposal`.
    package func dimensions(_ proposal: ProposedViewSize) -> ViewDimensions {
        let key = ProposalKey(proposal)
        if let d = dims[key] { return d }
        let size = sizeThatFits(proposal)
        let d = ViewDimensions(size: size, guides: ExplicitGuides { [unowned self] k in
            self.behavior.explicitAlignment(k, size: size, proposal: proposal, node: self)
        })
        dims[key] = d
        return d
    }

    package var spacing: ViewSpacing { behavior.spacing(node: self) }
    package var layoutPriority: Double { behavior.layoutPriority(node: self) }
    package func layoutValue(_ key: ObjectIdentifier) -> Any? { behavior.layoutValue(key, node: self) }

    /// Child placements for this node at `size` and `proposal` (memoised).
    package func placements(size: CGSize, proposal: ProposedViewSize) -> [ChildPlacement] {
        let key = PlacementKey(size: size, proposal: proposal)
        if let p = placementMemo[key] { return p }
        let p = behavior.placeChildren(size: size, proposal: proposal, node: self)
        placementMemo[key] = p
        return p
    }

    /// The explicit value of `key` contributed by child `index`, in this
    /// node's coordinates (child origin + the child's own explicit value).
    package func childExplicitAlignment(_ key: AlignmentKey, child index: Int, size: CGSize,
                                        proposal: ProposedViewSize) -> CGFloat? {
        guard let pl = placements(size: size, proposal: proposal).first(where: { $0.index == index }),
              let v = children[index].dimensions(pl.proposal).explicitValue(key) else { return nil }
        return pl.origin[key.axis] + v
    }

    // MARK: Placing

    /// Places this node with its top-leading corner at `origin` (parent
    /// coordinates), recursively.
    package func place(at origin: CGPoint, size: CGSize, proposal: ProposedViewSize,
                       parentTransform: AffineTransform2D = .identity) {
        let t = parentTransform.concatenating(.translation(origin.x, origin.y))
        placedTransform = t
        placedLocalOrigin = origin
        placedSize = size
        placedProposal = proposal
        placedFrame = t.boundingBox(of: CGRect(origin: .zero, size: size))
        let childT = behavior.childTransform(size: size).map { t.concatenating($0) } ?? t
        var pls = placements(size: size, proposal: proposal)
        if let expanding = behavior as? any SafeAreaExpandingBehavior {
            pls = expanding.expand(pls, node: self, frame: placedFrame!)
        }
        for pl in pls {
            children[pl.index].place(at: pl.origin, size: pl.size, proposal: pl.proposal, parentTransform: childT)
        }
    }

    /// Visits this node and its descendants, depth first.
    package func forEachNode(_ body: (LayoutNode) -> Void) {
        body(self)
        for c in children { c.forEachNode(body) }
    }
}

/// A render-time effect on a node's children whose value may be animating:
/// an opacity, or a transform replacing the behaviour's layout-time one.
package enum PresentationEffect {
    case opacity(@MainActor () -> Double)
    case transform(@MainActor (CGSize) -> AffineTransform2D)
}

private struct PlacementKey: Hashable {
    let w: Double, h: Double
    let p: ProposalKey
    init(size: CGSize, proposal: ProposedViewSize) {
        w = Double(size.width)
        h = Double(size.height)
        p = ProposalKey(proposal)
    }
}

/// A behaviour that grows its child into the safe-area insets it touches.
package protocol SafeAreaExpandingBehavior: NodeBehavior {
    func expand(_ placements: [ChildPlacement], node: LayoutNode, frame: CGRect) -> [ChildPlacement]
}

/// A 2D affine transform (x' = a·x + c·y + tx, y' = b·x + d·y + ty).
package struct AffineTransform2D: Equatable {
    package var a: CGFloat, b: CGFloat, c: CGFloat, d: CGFloat, tx: CGFloat, ty: CGFloat

    package static let identity = AffineTransform2D(a: 1, b: 0, c: 0, d: 1, tx: 0, ty: 0)

    package static func translation(_ x: CGFloat, _ y: CGFloat) -> AffineTransform2D {
        AffineTransform2D(a: 1, b: 0, c: 0, d: 1, tx: x, ty: y)
    }

    package static func scale(_ sx: CGFloat, _ sy: CGFloat) -> AffineTransform2D {
        AffineTransform2D(a: sx, b: 0, c: 0, d: sy, tx: 0, ty: 0)
    }

    /// Rotation by `radians`, clockwise on screen (y grows downwards).
    package static func rotation(_ radians: Double) -> AffineTransform2D {
        let (s, c) = (CGFloat(sin(radians)), CGFloat(cos(radians)))
        return AffineTransform2D(a: c, b: s, c: -s, d: c, tx: 0, ty: 0)
    }

    /// `self ∘ other`: applies `other` first, then `self`.
    package func concatenating(_ o: AffineTransform2D) -> AffineTransform2D {
        AffineTransform2D(a: a * o.a + c * o.b, b: b * o.a + d * o.b,
                          c: a * o.c + c * o.d, d: b * o.c + d * o.d,
                          tx: a * o.tx + c * o.ty + tx, ty: b * o.tx + d * o.ty + ty)
    }

    package func apply(_ p: CGPoint) -> CGPoint {
        CGPoint(x: a * p.x + c * p.y + tx, y: b * p.x + d * p.y + ty)
    }

    /// The transform about `anchor` (in the same coordinates).
    package func about(_ anchor: CGPoint) -> AffineTransform2D {
        AffineTransform2D.translation(anchor.x, anchor.y).concatenating(self)
            .concatenating(.translation(-anchor.x, -anchor.y))
    }

    package func boundingBox(of r: CGRect) -> CGRect {
        if b == 0 && c == 0 {
            // Axis-aligned: avoid ∞·0 for infinite sizes.
            let x0 = a * r.minX + tx, x1 = a * r.maxX + tx
            let y0 = d * r.minY + ty, y1 = d * r.maxY + ty
            return CGRect(x: min(x0, x1), y: min(y0, y1), width: abs(x1 - x0), height: abs(y1 - y0))
        }
        let pts = [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
                   CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY)].map(apply)
        let xs = pts.map(\.x), ys = pts.map(\.y)
        return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }
}
