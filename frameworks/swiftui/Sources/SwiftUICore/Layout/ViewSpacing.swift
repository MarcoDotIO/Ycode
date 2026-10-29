import Foundation

// Spacing preferences (04-layout.md §4.1, golden-layout.md "Default spacing
// between kinds of views").
//
// Every view carries, for each of its four edges, a set of preferences. The
// distance between two adjacent views is the largest value over all pairs of
// (preference on the first view's trailing/bottom edge, preference on the
// second view's leading/top edge). An edge with no preferences (a `Spacer`,
// `ViewSpacing.zero`) gives distance 0 against anything.
//
// Model (ours; the closed form from font metrics is open, 10-plan.md §4 q.7):
// a preference has a kind and two values:
//   - `standard` edges (colours, shapes, padded views, controls) want 8 to
//     every neighbour;
//   - `text` and `image` edges are baseline-relative: against a standard
//     neighbour they want their own `towardStandard` value (which differs
//     above and below the view, e.g. body text 6.43 above and 10.64 below),
//     and against another text/image edge the pair uses the smaller of the
//     two `towardText` values (text–text 2, anything involving a symbol 0).
// Horizontally every kind measured 8.

/// One spacing preference on one edge of a view.
package struct SpacingPreference: Hashable, Sendable {
    package enum Kind: Hashable, Sendable {
        case standard
        case text
        case image
    }

    package var kind: Kind
    /// Wanted distance to a standard neighbour on this edge.
    package var towardStandard: CGFloat
    /// Wanted distance to a text or image neighbour (text/image kinds only).
    package var towardText: CGFloat

    package init(kind: Kind, towardStandard: CGFloat, towardText: CGFloat = 0) {
        self.kind = kind
        self.towardStandard = towardStandard
        self.towardText = towardText
    }

    /// The default preference: 8 on every edge (iOS).
    package static let standard = SpacingPreference(kind: .standard, towardStandard: 8)

    /// Distance between `a` (on the first view) and `b` (on the next one).
    package static func distance(_ a: SpacingPreference, _ b: SpacingPreference) -> CGFloat {
        switch (a.kind, b.kind) {
        case (.standard, .standard): return max(a.towardStandard, b.towardStandard)
        case (.standard, _): return b.towardStandard
        case (_, .standard): return a.towardStandard
        default: return min(a.towardText, b.towardText)
        }
    }
}

/// The spacing preferences of a view on each of its edges.
public struct ViewSpacing: Sendable {
    package var top: [SpacingPreference]
    package var leading: [SpacingPreference]
    package var bottom: [SpacingPreference]
    package var trailing: [SpacingPreference]

    package init(top: [SpacingPreference], leading: [SpacingPreference],
                 bottom: [SpacingPreference], trailing: [SpacingPreference]) {
        self.top = top
        self.leading = leading
        self.bottom = bottom
        self.trailing = trailing
    }

    /// No preferences: zero distance to every neighbour.
    public static let zero = ViewSpacing(top: [], leading: [], bottom: [], trailing: [])

    /// The default preferences of a view (8 on every edge).
    public init() {
        self.init(top: [.standard], leading: [.standard], bottom: [.standard], trailing: [.standard])
    }

    /// Adds `other`'s preferences on `edges` to this value's.
    public mutating func formUnion(_ other: ViewSpacing, edges: Edge.Set = .all) {
        func merge(_ a: inout [SpacingPreference], _ b: [SpacingPreference]) {
            for p in b where !a.contains(p) { a.append(p) }
        }
        if edges.contains(.top) { merge(&top, other.top) }
        if edges.contains(.leading) { merge(&leading, other.leading) }
        if edges.contains(.bottom) { merge(&bottom, other.bottom) }
        if edges.contains(.trailing) { merge(&trailing, other.trailing) }
    }

    public func union(_ other: ViewSpacing, edges: Edge.Set = .all) -> ViewSpacing {
        var r = self
        r.formUnion(other, edges: edges)
        return r
    }

    /// The distance from this view to `next`, which follows it along `axis`
    /// (to its trailing side horizontally, below it vertically).
    public func distance(to next: ViewSpacing, along axis: Axis) -> CGFloat {
        let a = axis == .horizontal ? trailing : bottom
        let b = axis == .horizontal ? next.leading : next.top
        var best: CGFloat?
        for p in a {
            for q in b {
                let d = SpacingPreference.distance(p, q)
                best = max(best ?? d, d)
            }
        }
        return best ?? 0
    }

    /// The preferences on `edges` replaced by `preferences`.
    package func replacing(_ edges: Edge.Set, with preferences: [SpacingPreference]) -> ViewSpacing {
        var r = self
        if edges.contains(.top) { r.top = preferences }
        if edges.contains(.leading) { r.leading = preferences }
        if edges.contains(.bottom) { r.bottom = preferences }
        if edges.contains(.trailing) { r.trailing = preferences }
        return r
    }
}
