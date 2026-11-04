import Foundation
#if OPENVIEWS_RENAMED
import OpenViewsCore
#else
import SwiftUICore
#endif

// `ScrollPosition` and `.scrollPosition(_:)` (public API names; L2,
// docs/PARITY.md §5.9): scrolling to a point from code. Only the point form:
// `scrollPosition(id:)` remains the way to follow lazy items.

/// A scroll view's position, set from code.
public struct ScrollPosition: Equatable, Sendable {
    /// The last point asked for.
    public private(set) var point: CGPoint?
    /// Which request this is: asking for the same point again scrolls again
    /// (the user may have scrolled away in between).
    var serial = 0

    public init(point: CGPoint) { self.point = point }
    public init(x: CGFloat, y: CGFloat) { point = CGPoint(x: x, y: y) }
    public init(x: CGFloat) { point = CGPoint(x: x, y: 0) }
    public init(y: CGFloat) { point = CGPoint(x: 0, y: y) }

    public mutating func scrollTo(point: CGPoint) {
        self.point = point
        serial &+= 1
    }

    public mutating func scrollTo(x: CGFloat, y: CGFloat) { scrollTo(point: CGPoint(x: x, y: y)) }
    public mutating func scrollTo(x: CGFloat) { scrollTo(point: CGPoint(x: x, y: point?.y ?? 0)) }
    public mutating func scrollTo(y: CGFloat) { scrollTo(point: CGPoint(x: point?.x ?? 0, y: y)) }
}

private enum ScrollPointKey: EnvironmentKey {
    static var defaultValue: Binding<ScrollPosition>? { nil }
}

extension EnvironmentValues {
    var _scrollPointBinding: Binding<ScrollPosition>? {
        get { self[ScrollPointKey.self] }
        set { self[ScrollPointKey.self] = newValue }
    }
}

extension View {
    /// Binds the scroll view inside to `position`: `position.scrollTo(…)` moves it.
    public func scrollPosition(_ position: Binding<ScrollPosition>, anchor: UnitPoint? = nil) -> some View {
        environment(\._scrollPointBinding, position)
    }
}

extension ScrollViewState {
    /// Applies a new request of the binding (once per serial; a request not
    /// yet in reach of the content waits for the next layout).
    @MainActor func applyScrollPoint(_ binding: Binding<ScrollPosition>?) {
        guard let binding else { return }
        let p = binding.wrappedValue
        if p.serial != appliedPointSerial {
            appliedPointSerial = p.serial
            if let point = p.point {
                pendingPoint = point
                setOffset(point)
            }
        }
    }

    /// After a layout: the content may have grown to where the request was.
    @MainActor func settleScrollPoint() {
        guard let p = pendingPoint else { return }
        pendingPoint = nil
        setOffset(p)
    }
}
