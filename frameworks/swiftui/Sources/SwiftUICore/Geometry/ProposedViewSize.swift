import Foundation

/// A size offered to a view by its parent (04-layout.md §1). Each dimension is
/// either a number, `nil` (unspecified: "your ideal size"), zero ("your
/// minimum") or infinity ("your maximum").
public struct ProposedViewSize: Equatable, Sendable {
    public var width: CGFloat?
    public var height: CGFloat?

    public init(width: CGFloat?, height: CGFloat?) {
        self.width = width
        self.height = height
    }

    public init(_ size: CGSize) { self.init(width: size.width, height: size.height) }

    public static let zero = ProposedViewSize(width: 0, height: 0)
    public static let unspecified = ProposedViewSize(width: nil, height: nil)
    public static let infinity = ProposedViewSize(width: .infinity, height: .infinity)

    /// A concrete size: unspecified dimensions become those of `size`
    /// (default 10 × 10, the size shapes and colours answer to `nil`).
    public func replacingUnspecifiedDimensions(by size: CGSize = CGSize(width: 10, height: 10)) -> CGSize {
        CGSize(width: width ?? size.width, height: height ?? size.height)
    }

    /// The dimension along `axis`.
    package subscript(axis: Axis) -> CGFloat? {
        get { axis == .horizontal ? width : height }
        set { if axis == .horizontal { width = newValue } else { height = newValue } }
    }

    /// A proposal built from a value along `axis` and one across it.
    package init(_ axis: Axis, along: CGFloat?, across: CGFloat?) {
        if axis == .horizontal { self.init(width: along, height: across) }
        else { self.init(width: across, height: along) }
    }
}

/// A hashable form of a proposal, for caches.
package struct ProposalKey: Hashable {
    let w: Double?
    let h: Double?
    package init(_ p: ProposedViewSize) {
        w = p.width.map(Double.init)
        h = p.height.map(Double.init)
    }
}

extension CGSize {
    /// The dimension along `axis`.
    package subscript(axis: Axis) -> CGFloat {
        get { axis == .horizontal ? width : height }
        set { if axis == .horizontal { width = newValue } else { height = newValue } }
    }

    package init(_ axis: Axis, along: CGFloat, across: CGFloat) {
        if axis == .horizontal { self.init(width: along, height: across) }
        else { self.init(width: across, height: along) }
    }
}

extension CGPoint {
    package subscript(axis: Axis) -> CGFloat {
        get { axis == .horizontal ? x : y }
        set { if axis == .horizontal { x = newValue } else { y = newValue } }
    }

    package init(_ axis: Axis, along: CGFloat, across: CGFloat) {
        if axis == .horizontal { self.init(x: along, y: across) }
        else { self.init(x: across, y: along) }
    }
}
