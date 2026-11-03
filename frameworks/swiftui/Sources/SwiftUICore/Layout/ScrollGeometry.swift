import Foundation

// Scroll geometry values (round R9). The names are the public API's
// (api-inventory.md: `ScrollGeometry`, `ScrollTarget` are SwiftUICore types).

/// The geometry of a scroll view: what `onScrollGeometryChange` reports.
public struct ScrollGeometry: Equatable, Sendable {
    /// The scrolled distance from the content's origin (positive downwards and
    /// towards the trailing edge).
    public var contentOffset: CGPoint
    /// The size of the content.
    public var contentSize: CGSize
    /// The insets the content scrolls under (the safe area it touches).
    public var contentInsets: EdgeInsets
    /// The size of the scroll view.
    public var containerSize: CGSize

    public init(contentOffset: CGPoint, contentSize: CGSize, contentInsets: EdgeInsets, containerSize: CGSize) {
        self.contentOffset = contentOffset
        self.contentSize = contentSize
        self.contentInsets = contentInsets
        self.containerSize = containerSize
    }

    /// The visible part of the content, in content coordinates.
    public var visibleRect: CGRect {
        CGRect(x: contentOffset.x - contentInsets.leading, y: contentOffset.y - contentInsets.top,
               width: containerSize.width + contentInsets.horizontal, height: containerSize.height + contentInsets.vertical)
    }

    /// The scroll view's own rectangle in content coordinates.
    public var bounds: CGRect { CGRect(origin: contentOffset, size: containerSize) }
}

/// A place a scroll view can come to rest at (scroll target behaviours).
public struct ScrollTarget: Hashable, Sendable {
    /// The rectangle (content coordinates) to show.
    public var rect: CGRect
    /// Where `rect` is put in the scroll view (nil: at the top-leading edge).
    public var anchor: UnitPoint?

    public init(rect: CGRect, anchor: UnitPoint? = nil) {
        self.rect = rect
        self.anchor = anchor
    }

    public static func == (a: ScrollTarget, b: ScrollTarget) -> Bool { a.rect == b.rect && a.anchor == b.anchor }

    public func hash(into h: inout Hasher) {
        h.combine(Double(rect.minX))
        h.combine(Double(rect.minY))
        h.combine(Double(rect.width))
        h.combine(Double(rect.height))
    }
}

/// Visibility of scroll indicators.
public struct ScrollIndicatorVisibility: Equatable, Sendable {
    package enum Kind: Equatable, Sendable { case automatic, visible, hidden, never }
    package let kind: Kind
    public static let automatic = ScrollIndicatorVisibility(kind: .automatic)
    public static let visible = ScrollIndicatorVisibility(kind: .visible)
    public static let hidden = ScrollIndicatorVisibility(kind: .hidden)
    public static let never = ScrollIndicatorVisibility(kind: .never)
}

private enum VerticalIndicatorKey: EnvironmentKey { static let defaultValue = ScrollIndicatorVisibility.automatic }
private enum HorizontalIndicatorKey: EnvironmentKey { static let defaultValue = ScrollIndicatorVisibility.automatic }
private enum ScrollEnabledKey: EnvironmentKey { static let defaultValue = true }

extension EnvironmentValues {
    public var verticalScrollIndicatorVisibility: ScrollIndicatorVisibility {
        get { self[VerticalIndicatorKey.self] }
        set { self[VerticalIndicatorKey.self] = newValue }
    }

    public var horizontalScrollIndicatorVisibility: ScrollIndicatorVisibility {
        get { self[HorizontalIndicatorKey.self] }
        set { self[HorizontalIndicatorKey.self] = newValue }
    }

    /// False inside `scrollDisabled(true)`.
    public var isScrollEnabled: Bool {
        get { self[ScrollEnabledKey.self] }
        set { self[ScrollEnabledKey.self] = newValue }
    }
}

extension View {
    public func scrollIndicators(_ visibility: ScrollIndicatorVisibility, axes: Axis.Set = [.vertical, .horizontal]) -> some View {
        transformEnvironment(\.self) { env in
            if axes.contains(.vertical) { env.verticalScrollIndicatorVisibility = visibility }
            if axes.contains(.horizontal) { env.horizontalScrollIndicatorVisibility = visibility }
        }
    }

    public func scrollDisabled(_ disabled: Bool) -> some View {
        transformEnvironment(\.isScrollEnabled) { if disabled { $0 = false } }
    }
}

#if !canImport(CoreGraphics)
/// CoreGraphics' vector, which swift-corelibs-foundation lacks on Linux (an
/// interop name of the scroll target API: the fling velocity).
public struct CGVector: Equatable, Hashable, Sendable {
    public var dx: CGFloat
    public var dy: CGFloat
    public init() { dx = 0; dy = 0 }
    public init(dx: CGFloat, dy: CGFloat) {
        self.dx = dx
        self.dy = dy
    }
    public static var zero: CGVector { CGVector() }
}
#endif
