import Foundation

// Primitive views (04-layout.md §2).

/// Colours and shapes: take the proposal, `nil` → 10.
package struct ShapeLeaf: NodeBehavior {
    package enum Kind: Sendable { case rectangle, circle }
    package var kind: Kind

    package init(_ kind: Kind = .rectangle) { self.kind = kind }

    package func sizeThatFits(_ p: ProposedViewSize, node: LayoutNode) -> CGSize {
        switch kind {
        case .rectangle:
            return p.replacingUnspecifiedDimensions()
        case .circle:
            // A square of the smaller proposed dimension; one nil → the other;
            // both nil → 10 × 10 (04 §2; golden `circle`).
            switch (p.width, p.height) {
            case (nil, nil): return CGSize(width: 10, height: 10)
            case (let w?, nil): return CGSize(width: w, height: w)
            case (nil, let h?): return CGSize(width: h, height: h)
            case (let w?, let h?): let s = min(w, h); return CGSize(width: s, height: s)
            }
        }
    }
}

/// `EmptyView`: zero size; containers leave it out.
package struct EmptyLeaf: NodeBehavior {
    package init() {}
    package var isEmpty: Bool { true }
    package func sizeThatFits(_ p: ProposedViewSize, node: LayoutNode) -> CGSize { .zero }
    package func spacing(node: LayoutNode) -> ViewSpacing { .zero }
}

/// `Spacer`: flexible along the enclosing stack's axis, never shorter than
/// its minimum length (default 8); zero across a stack; outside a stack the
/// rule applies to both dimensions. Priority −∞, no spacing preferences.
package struct SpacerLeaf: NodeBehavior {
    package var minLength: CGFloat?

    package init(minLength: CGFloat? = nil) { self.minLength = minLength }

    /// iOS default minimum length.
    package static let defaultMinLength: CGFloat = 8

    package func sizeThatFits(_ p: ProposedViewSize, node: LayoutNode) -> CGSize {
        let m = minLength ?? SpacerLeaf.defaultMinLength
        func along(_ v: CGFloat?) -> CGFloat { v.map { Swift.max($0, m) } ?? m }
        switch node.stackOrientation {
        case .horizontal?: return CGSize(width: along(p.width), height: 0)
        case .vertical?: return CGSize(width: 0, height: along(p.height))
        case nil: return CGSize(width: along(p.width), height: along(p.height))
        }
    }

    package func spacing(node: LayoutNode) -> ViewSpacing { .zero }
    package func layoutPriority(node: LayoutNode) -> Double { -.infinity }
}

/// `GeometryReader`: takes the proposal (`nil` → 10) and places its content
/// at its top-leading corner, proposing its own size.
package struct GeometryReaderBehavior: NodeBehavior {
    package init() {}

    package func childStackOrientation(inherited: Axis?, child index: Int) -> Axis? { nil }

    package func sizeThatFits(_ p: ProposedViewSize, node: LayoutNode) -> CGSize {
        p.replacingUnspecifiedDimensions()
    }

    package func placeChildren(size: CGSize, proposal: ProposedViewSize, node: LayoutNode) -> [ChildPlacement] {
        node.children.indices.map { i in
            let s = node.children[i].sizeThatFits(ProposedViewSize(size))
            return ChildPlacement(index: i, origin: .zero, size: s, proposal: ProposedViewSize(size))
        }
    }
}

/// `Text`, measured by the context's text measurer (Text/TextMeasurer.swift).
package struct TextLeaf: NodeBehavior {
    package var text: ResolvedText

    package init(_ text: ResolvedText) { self.text = text }

    package init(_ string: String, font: TextFont = .body, lineLimit: Int? = nil) {
        self.init(ResolvedText(string, font: font, lineLimit: lineLimit))
    }

    /// The text's characters.
    package var string: String { text.string }
    /// The font of the first run.
    package var font: TextFont { text.firstFont }
    package var lineLimit: Int? { text.paragraph.lineLimit }

    private func measure(_ p: ProposedViewSize, _ node: LayoutNode) -> TextMeasurement {
        let m = node.context.textMeasurer.measure(text, proposal: p)
        node.context.uncertain(m.unknown)
        return m
    }

    package func sizeThatFits(_ p: ProposedViewSize, node: LayoutNode) -> CGSize { measure(p, node).size }

    package func explicitAlignment(_ key: AlignmentKey, size: CGSize, proposal: ProposedViewSize,
                                   node: LayoutNode) -> CGFloat? {
        let isFirst = key == VerticalAlignment.firstTextBaseline.key
        let isLast = key == VerticalAlignment.lastTextBaseline.key
        guard isFirst || isLast else { return nil }
        let m = measure(proposal, node)
        let v = isFirst ? m.firstBaseline : m.lastBaseline
        if v == nil { node.context.uncertain(.vertical) }
        return v
    }

    package func spacing(node: LayoutNode) -> ViewSpacing {
        let measurer = node.context.textMeasurer
        let top = measurer.spacing(for: text.firstFont).above
        let bottom = measurer.spacing(for: text.lastFont).below
        return ViewSpacing(top: [top], leading: [.standard], bottom: [bottom], trailing: [.standard])
    }
}

/// `Image`: a symbol (`Image(systemName:)`) or an image of known natural
/// size. Not resizable: a fixed size that ignores proposals. Resizable: takes
/// the proposal, `nil` → the natural size (04 §2).
package struct ImageLeaf: NodeBehavior {
    package enum Source: Sendable {
        case symbol(String)
        case natural(CGSize)
    }
    package var source: Source
    package var resizable: Bool
    package var font: TextFont

    package init(_ source: Source, resizable: Bool = false, font: TextFont = .body) {
        self.source = source
        self.resizable = resizable
        self.font = font
    }

    private func metrics(_ node: LayoutNode) -> SymbolMetrics? {
        switch source {
        case .symbol(let name): return node.context.symbols.symbol(named: name, font: font)
        case .natural(let s): return SymbolMetrics(size: s, baselineOffset: 0, naturalSize: s)
        }
    }

    package func sizeThatFits(_ p: ProposedViewSize, node: LayoutNode) -> CGSize {
        guard let m = metrics(node) else { return .zero }
        if resizable { return p.replacingUnspecifiedDimensions(by: m.naturalSize) }
        return m.size
    }

    package func explicitAlignment(_ key: AlignmentKey, size: CGSize, proposal: ProposedViewSize,
                                   node: LayoutNode) -> CGFloat? {
        guard !resizable, case .symbol = source, let m = metrics(node),
              key == VerticalAlignment.firstTextBaseline.key || key == VerticalAlignment.lastTextBaseline.key
        else { return nil }
        // Symbols sit on the text baseline (07 §3).
        return size.height - m.baselineOffset
    }

    package func spacing(node: LayoutNode) -> ViewSpacing {
        guard case .symbol = source else { return ViewSpacing() }
        let s = node.context.symbols
        return ViewSpacing(top: [s.spacingAbove], leading: [.standard], bottom: [s.spacingBelow], trailing: [.standard])
    }
}
