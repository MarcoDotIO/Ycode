import Foundation

/// A type-erased layout, so that a container can switch layouts while
/// keeping its subviews' identities.
public struct AnyLayout: Layout, Sendable {
    private let box: any AnyLayoutBox

    public init<L: Layout>(_ layout: L) { box = ConcreteLayoutBox(layout: layout) }

    /// The wrapped layout's cache, type-erased.
    public struct Cache {
        fileprivate var value: Any
    }

    public typealias AnimatableData = EmptyAnimatableData

    public func makeCache(subviews: Subviews) -> Cache { Cache(value: box.makeCache(subviews)) }

    public func updateCache(_ cache: inout Cache, subviews: Subviews) { box.updateCache(&cache.value, subviews) }

    public func spacing(subviews: Subviews, cache: inout Cache) -> ViewSpacing {
        box.spacing(subviews, &cache.value)
    }

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        box.sizeThatFits(proposal, subviews, &cache.value)
    }

    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        box.placeSubviews(bounds, proposal, subviews, &cache.value)
    }

    public func explicitAlignment(of guide: HorizontalAlignment, in bounds: CGRect, proposal: ProposedViewSize,
                                  subviews: Subviews, cache: inout Cache) -> CGFloat? {
        box.explicitAlignment(guide.key, bounds, proposal, subviews, &cache.value)
    }

    public func explicitAlignment(of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize,
                                  subviews: Subviews, cache: inout Cache) -> CGFloat? {
        box.explicitAlignment(guide.key, bounds, proposal, subviews, &cache.value)
    }

    /// The wrapped layout's stack orientation (for `Spacer`/`Divider`).
    package var stackOrientation: Axis? { box.stackOrientation }
}

private protocol AnyLayoutBox: Sendable {
    var stackOrientation: Axis? { get }
    func makeCache(_ s: LayoutSubviews) -> Any
    func updateCache(_ c: inout Any, _ s: LayoutSubviews)
    func spacing(_ s: LayoutSubviews, _ c: inout Any) -> ViewSpacing
    func sizeThatFits(_ p: ProposedViewSize, _ s: LayoutSubviews, _ c: inout Any) -> CGSize
    func placeSubviews(_ b: CGRect, _ p: ProposedViewSize, _ s: LayoutSubviews, _ c: inout Any)
    func explicitAlignment(_ k: AlignmentKey, _ b: CGRect, _ p: ProposedViewSize, _ s: LayoutSubviews, _ c: inout Any) -> CGFloat?
}

private struct ConcreteLayoutBox<L: Layout>: AnyLayoutBox {
    let layout: L

    var stackOrientation: Axis? { L.layoutProperties.stackOrientation }

    private func with<R>(_ c: inout Any, _ s: LayoutSubviews, _ body: (inout L.Cache) -> R) -> R {
        var cache = (c as? L.Cache) ?? layout.makeCache(subviews: s)
        let r = body(&cache)
        c = cache
        return r
    }

    func makeCache(_ s: LayoutSubviews) -> Any { layout.makeCache(subviews: s) }
    func updateCache(_ c: inout Any, _ s: LayoutSubviews) { with(&c, s) { layout.updateCache(&$0, subviews: s) } }
    func spacing(_ s: LayoutSubviews, _ c: inout Any) -> ViewSpacing { with(&c, s) { layout.spacing(subviews: s, cache: &$0) } }
    func sizeThatFits(_ p: ProposedViewSize, _ s: LayoutSubviews, _ c: inout Any) -> CGSize {
        with(&c, s) { layout.sizeThatFits(proposal: p, subviews: s, cache: &$0) }
    }
    func placeSubviews(_ b: CGRect, _ p: ProposedViewSize, _ s: LayoutSubviews, _ c: inout Any) {
        with(&c, s) { layout.placeSubviews(in: b, proposal: p, subviews: s, cache: &$0) }
    }
    func explicitAlignment(_ k: AlignmentKey, _ b: CGRect, _ p: ProposedViewSize, _ s: LayoutSubviews, _ c: inout Any) -> CGFloat? {
        with(&c, s) { cache in
            k.axis == .horizontal
                ? layout.explicitAlignment(of: HorizontalAlignment(key: k), in: b, proposal: p, subviews: s, cache: &cache)
                : layout.explicitAlignment(of: VerticalAlignment(key: k), in: b, proposal: p, subviews: s, cache: &cache)
        }
    }
}
