import Foundation
#if OPENVIEWS_RENAMED
import OpenViewsCore
#else
import SwiftUICore
#endif

/// A column (or row) description for lazy grids.
public struct GridItem: Sendable, Equatable {
    /// How the column is sized.
    public enum Size: Sendable, Equatable {
        /// Exactly this width.
        case fixed(CGFloat)
        /// A share of the free width, within the bounds.
        case flexible(minimum: CGFloat = 10, maximum: CGFloat = .infinity)
        /// As many columns of at least `minimum` as fit, sharing the width.
        case adaptive(minimum: CGFloat, maximum: CGFloat = .infinity)
    }

    public var size: Size
    /// Spacing after this item (nil → 8).
    public var spacing: CGFloat?
    /// Alignment of cells in this item (nil → centre).
    public var alignment: Alignment?

    public init(_ size: Size = .flexible(), spacing: CGFloat? = nil, alignment: Alignment? = nil) {
        self.size = size
        self.spacing = spacing
        self.alignment = alignment
    }
}

/// The layout of `LazyVGrid` (04 §6, golden `lazyvgrid.*`).
///
/// Columns are resolved from the offered width first: fixed items take their
/// width; flexible items share what is left (least flexible first, within
/// their bounds); an adaptive item becomes as many columns of at least its
/// minimum as fit in its share. Cells fill rows left to right (leading to
/// trailing), each row as tall as its tallest cell (cells are proposed their
/// column width and an unspecified height); rows are 8 apart unless
/// `spacing` says otherwise. The grid answers max(offer, columns) wide and
/// its content height tall; an unspecified width gives each column its
/// cells' ideal width (an adaptive item one column); an infinite width gives
/// an empty grid (observed: 0 × 0).
package struct LazyVGridLayout: Layout {
    package var columns: [GridItem]
    package var alignment: HorizontalAlignment
    package var spacing: CGFloat?

    package init(columns: [GridItem], alignment: HorizontalAlignment = .center, spacing: CGFloat? = nil) {
        self.columns = columns
        self.alignment = alignment
        self.spacing = spacing
    }

    package typealias Cache = Void

    private static let defaultSpacing: CGFloat = 8

    private struct Column {
        var width: CGFloat
        var spacingAfter: CGFloat
        var alignment: Alignment
    }

    private func resolveColumns(_ width: CGFloat?, _ s: Subviews) -> [Column]? {
        if let w = width, w.isInfinite { return nil }
        let gap: (GridItem) -> CGFloat = { $0.spacing ?? Self.defaultSpacing }
        guard let w = width else {
            // Ideal width: one column per item; non-fixed columns as wide as
            // their cells' ideal widths.
            let n = columns.count
            return columns.enumerated().map { k, item in
                let width: CGFloat
                if case .fixed(let f) = item.size { width = f } else {
                    width = stride(from: k, to: s.count, by: Swift.max(n, 1))
                        .map { s[$0].sizeThatFits(.unspecified).width }.max() ?? 0
                }
                return Column(width: width, spacingAfter: gap(item), alignment: item.alignment ?? .center)
            }
        }
        let gaps = columns.dropLast().reduce(CGFloat(0)) { $0 + gap($1) }
        // Fixed items go first (higher priority); flexible and adaptive items
        // share the rest.
        let items = columns.map { item -> DistributionItem in
            switch item.size {
            case .fixed(let f):
                return DistributionItem(minLength: f, maxLength: f, priority: 1, measure: { _ in f })
            case .flexible(let lo, let hi):
                return DistributionItem(minLength: lo, maxLength: hi, priority: 0,
                                        measure: { Swift.min(Swift.max($0, lo), hi) })
            case .adaptive(let lo, _):
                return DistributionItem(minLength: 0, maxLength: .infinity, priority: 0,
                                        measure: { $0 }).with(min: lo)
            }
        }
        let shares = distribute(w - gaps, items)
        var result: [Column] = []
        for (k, item) in columns.enumerated() {
            let share = shares[k].length
            switch item.size {
            case .adaptive(let lo, let hi):
                let sp = gap(item)
                let n = share <= 0 ? 0 : Swift.max(1, Int(((share + sp) / (lo + sp)).rounded(.down)))
                guard n > 0 else { continue }
                let cw = Swift.min(Swift.max((share - CGFloat(n - 1) * sp) / CGFloat(n), 0), hi)
                for i in 0..<n {
                    result.append(Column(width: cw, spacingAfter: i == n - 1 ? gap(item) : sp, alignment: item.alignment ?? .center))
                }
            default:
                result.append(Column(width: share, spacingAfter: gap(item), alignment: item.alignment ?? .center))
            }
        }
        return result
    }

    private struct Arrangement {
        var columns: [Column]
        var rowHeights: [CGFloat]
        var columnsWidth: CGFloat
        var size: CGSize
    }

    private func arrange(_ p: ProposedViewSize, _ s: Subviews) -> Arrangement {
        guard let cols = resolveColumns(p.width, s), !cols.isEmpty else {
            return Arrangement(columns: [], rowHeights: [], columnsWidth: 0,
                               size: CGSize(width: p.width.map { $0.isInfinite ? 0 : $0 } ?? 0, height: 0))
        }
        let n = cols.count
        let rows = (s.count + n - 1) / n
        let heights = (0..<rows).map { r in
            (0..<n).compactMap { c -> CGFloat? in
                let i = r * n + c
                guard i < s.count else { return nil }
                return s[i].sizeThatFits(ProposedViewSize(width: cols[c].width, height: nil)).height
            }.max() ?? 0
        }
        let columnsWidth = cols.reduce(0) { $0 + $1.width } + cols.dropLast().reduce(0) { $0 + $1.spacingAfter }
        let rowGap = spacing ?? Self.defaultSpacing
        let height = heights.reduce(0, +) + CGFloat(Swift.max(rows - 1, 0)) * rowGap
        let width = Swift.max(p.width ?? columnsWidth, columnsWidth)
        return Arrangement(columns: cols, rowHeights: heights, columnsWidth: columnsWidth,
                           size: CGSize(width: width, height: height))
    }

    package func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        arrange(proposal, subviews).size
    }

    package func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        let a = arrange(proposal, subviews)
        let n = a.columns.count
        guard n > 0 else { return }
        let unit = Swift.min(Swift.max(alignment.key.defaultValue(for: CGSize(width: 1, height: 1)), 0), 1)
        let x0 = bounds.minX + (bounds.width - a.columnsWidth) * unit
        let rowGap = spacing ?? Self.defaultSpacing
        var y = bounds.minY
        for (r, rh) in a.rowHeights.enumerated() {
            var x = x0
            for c in 0..<n {
                let i = r * n + c
                guard i < subviews.count else { break }
                let col = a.columns[c]
                let prop = ProposedViewSize(width: col.width, height: nil)
                let d = subviews[i].dimensions(in: prop)
                let o = alignedOrigin(d, in: CGSize(width: col.width, height: rh), alignment: col.alignment)
                subviews[i].place(at: CGPoint(x: x + o.x, y: y + o.y), anchor: .topLeading, proposal: prop)
                x += col.width + col.spacingAfter
            }
            y += rh + rowGap
        }
    }
}

private extension DistributionItem {
    func with(min: CGFloat) -> DistributionItem {
        var c = self
        c.minLength = min
        return c
    }
}

extension LayoutNode {
    package static func lazyVGrid(columns: [GridItem], alignment: HorizontalAlignment = .center,
                                  spacing: CGFloat? = nil, _ children: [LayoutNode]) -> LayoutNode {
        layout(LazyVGridLayout(columns: columns, alignment: alignment, spacing: spacing), children)
    }
}
