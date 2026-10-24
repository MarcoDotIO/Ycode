import Foundation

/// Runs layout passes over node trees.
///
/// Coordinates: layout works in layout-direction terms (x grows towards the
/// trailing side). Results are reported in left-to-right absolute
/// coordinates: under `.rightToLeft` every frame is mirrored about the root's
/// width (x' = W − x − w; 08-environment-accessibility-localization.md §3,
/// 10-plan.md T-RTL), which reverses stacks, flips leading/trailing
/// alignment and negates horizontal offsets.
package struct LayoutEngine {
    package var environment: EnvironmentValues
    package var textMeasurer: any TextMeasurer
    package var symbols: any SymbolProvider

    package init(environment: EnvironmentValues = EnvironmentValues(),
                 textMeasurer: any TextMeasurer = TypesetTextMeasurer.shared,
                 symbols: any SymbolProvider = StubSymbolProvider()) {
        self.environment = environment
        self.textMeasurer = textMeasurer
        self.symbols = symbols
    }

    @discardableResult
    package func prepare(_ root: LayoutNode) -> LayoutContext {
        let ctx = LayoutContext(environment: environment, textMeasurer: textMeasurer, symbols: symbols)
        root.prepare(context: ctx)
        return ctx
    }

    /// The root's answer to `proposal`, and whether it was exact.
    package func sizeThatFits(_ root: LayoutNode, _ proposal: ProposedViewSize) -> (size: CGSize, exact: Bool) {
        let ctx = prepare(root)
        let s = root.sizeThatFits(proposal)
        return (s, ctx.uncertainCount == 0)
    }

    /// Sizes the root for `proposal`, places it at the origin and reports
    /// the frames of named nodes.
    package func layout(_ root: LayoutNode, proposal: ProposedViewSize) -> LayoutResult {
        let ctx = prepare(root)
        let size = root.sizeThatFits(proposal)
        root.place(at: .zero, size: size, proposal: proposal)
        return LayoutResult(root: root, context: ctx, size: size, proposal: proposal,
                            mirrorWidth: environment.layoutDirection == .rightToLeft ? size.width : nil)
    }

    /// Lays the root out as the content of a window: it is proposed the
    /// safe-area rectangle and placed in it (04 §1, §7). `safeAreaInsets` are
    /// in layout-direction terms (on the reference device: bottom 34 and
    /// trailing 84 in left-to-right; leading 84 in right-to-left).
    package func layout(_ root: LayoutNode, window: CGSize, safeAreaInsets insets: EdgeInsets) -> LayoutResult {
        let ctx = prepare(root)
        let windowRect = CGRect(origin: .zero, size: window)
        let safe = CGRect(x: insets.leading, y: insets.top,
                          width: Swift.max(window.width - insets.horizontal, 0),
                          height: Swift.max(window.height - insets.vertical, 0))
        ctx.safeArea = (windowRect, safe)
        let proposal = ProposedViewSize(safe.size)
        let size = root.sizeThatFits(proposal)
        // The root is centred in the safe rectangle when it does not fill it.
        let origin = CGPoint(x: safe.minX + (safe.width - size.width) / 2, y: safe.minY + (safe.height - size.height) / 2)
        root.place(at: origin, size: size, proposal: proposal)
        return LayoutResult(root: root, context: ctx, size: size, proposal: proposal,
                            mirrorWidth: environment.layoutDirection == .rightToLeft ? window.width : nil)
    }
}

/// The outcome of a layout pass.
package struct LayoutResult {
    package let root: LayoutNode
    package let context: LayoutContext
    package let size: CGSize
    package let proposal: ProposedViewSize
    /// Width to mirror frames about (right-to-left), or nil.
    package let mirrorWidth: CGFloat?

    /// The root's first and last text baselines (explicit or default).
    package var baselines: (first: CGFloat, last: CGFloat) {
        let d = root.dimensions(proposal)
        return (d[VerticalAlignment.firstTextBaseline], d[VerticalAlignment.lastTextBaseline])
    }

    /// True if no answer in this pass was approximate. Read it after every
    /// value of interest (baselines are computed lazily).
    package var isExact: Bool { context.uncertainCount == 0 }

    /// The frame of `node` in root coordinates (left-to-right absolute).
    package func frame(of node: LayoutNode) -> CGRect? {
        guard var f = node.placedFrame else { return nil }
        if let w = mirrorWidth { f.origin.x = w - f.origin.x - f.width }
        return f
    }

    /// Frames of all named nodes that were placed.
    package var namedFrames: [String: CGRect] {
        var r: [String: CGRect] = [:]
        root.forEachNode { n in
            if let name = n.name, let f = frame(of: n) { r[name] = f }
        }
        return r
    }

    package func node(named name: String) -> LayoutNode? {
        var found: LayoutNode?
        root.forEachNode { if found == nil && $0.name == name { found = $0 } }
        return found
    }

    /// Safe-area insets a geometry reader at `node` reports, in
    /// layout-direction terms: on each edge where the node's frame reaches the
    /// safe-area boundary (from inside, or extending into the inset), the
    /// window's inset on that edge; zero on the other edges.
    package func safeAreaInsets(of node: LayoutNode) -> EdgeInsets {
        guard let area = context.safeArea, let f = node.placedFrame else { return EdgeInsets() }
        let eps: CGFloat = 0.001
        var r = EdgeInsets()
        if f.minY <= area.safe.minY + eps { r.top = area.safe.minY - area.window.minY }
        if f.minX <= area.safe.minX + eps { r.leading = area.safe.minX - area.window.minX }
        if f.maxY >= area.safe.maxY - eps { r.bottom = area.window.maxY - area.safe.maxY }
        if f.maxX >= area.safe.maxX - eps { r.trailing = area.window.maxX - area.safe.maxX }
        return r
    }
}
