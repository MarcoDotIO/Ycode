import Foundation
#if OPENVIEWS_RENAMED
import OpenViewsCore
#else
import SwiftUICore
#endif

// `Grid` / `GridRow` (04-layout.md §6). Column width = the widest cell in the
// column, row height = the tallest cell in the row; widths and heights are
// distributed like a stack's children (least flexible first) when the grid
// is offered a concrete size, so a flexible cell expands its column/row to
// take what is left. Default spacing: the cells' preferences (8 between
// columns; between rows the vertical preferences of the touching cells).

/// Row membership of a grid cell (attached by the `grid` builder).
package enum GridRowIndexKey: LayoutValueKey {
    package static let defaultValue: Int? = nil
}

/// True for a direct child of a grid that is not in a `GridRow`: it takes a
/// whole row.
package enum GridFullRowKey: LayoutValueKey {
    package static let defaultValue = false
}

/// The vertical alignment of the cell's row (`GridRow(alignment:)`).
package enum GridRowAlignmentKey: LayoutValueKey {
    package static let defaultValue: VerticalAlignment? = nil
}

/// `gridCellColumns(_:)`.
package enum GridCellColumnsKey: LayoutValueKey {
    package static let defaultValue = 1
}

/// A two-dimensional layout of rows of cells.
public struct GridLayout: Layout {
    public var alignment: Alignment
    public var horizontalSpacing: CGFloat?
    public var verticalSpacing: CGFloat?

    public init(alignment: Alignment = .center, horizontalSpacing: CGFloat? = nil, verticalSpacing: CGFloat? = nil) {
        self.alignment = alignment
        self.horizontalSpacing = horizontalSpacing
        self.verticalSpacing = verticalSpacing
    }

    public typealias AnimatableData = EmptyAnimatableData

    /// The grid's structure: which subview sits in which row and columns.
    public struct Cache {
        struct Cell {
            var subview: Int
            var row: Int
            var column: Int
            var span: Int
            var rowAlignment: VerticalAlignment?
        }
        var cells: [Cell] = []
        var rowCount = 0
        var columnCount = 0
    }

    public func makeCache(subviews: Subviews) -> Cache {
        var cache = Cache()
        var rowOf: [Int: Int] = [:]   // builder row index → our row
        var columnCursor: [Int: Int] = [:]
        var fullRows: [Int] = []
        for (i, sv) in subviews.enumerated() {
            let row: Int
            if let r = sv[GridRowIndexKey.self], !sv[GridFullRowKey.self] {
                if let mapped = rowOf[r] { row = mapped } else {
                    row = cache.rowCount
                    rowOf[r] = row
                    cache.rowCount += 1
                }
            } else {
                row = cache.rowCount
                cache.rowCount += 1
                fullRows.append(cache.cells.count)
            }
            let span = Swift.max(1, sv[GridCellColumnsKey.self])
            let col = columnCursor[row, default: 0]
            columnCursor[row] = col + span
            cache.cells.append(.init(subview: i, row: row, column: col, span: span, rowAlignment: sv[GridRowAlignmentKey.self]))
        }
        cache.columnCount = Swift.max(1, cache.cells.indices.filter { !fullRows.contains($0) }
            .map { cache.cells[$0].column + cache.cells[$0].span }.max() ?? 1)
        for i in fullRows { cache.cells[i].span = cache.columnCount }
        return cache
    }

    private func columnGaps(_ s: Subviews, _ c: Cache) -> [CGFloat] {
        guard c.columnCount > 1 else { return [] }
        return (0..<(c.columnCount - 1)).map { j in
            if let h = horizontalSpacing { return h }
            var before = ViewSpacing.zero, after = ViewSpacing.zero
            for cell in c.cells {
                if cell.column + cell.span - 1 == j { before.formUnion(s[cell.subview].spacing, edges: .trailing) }
                if cell.column == j + 1 { after.formUnion(s[cell.subview].spacing, edges: .leading) }
            }
            return before.distance(to: after, along: .horizontal)
        }
    }

    private func rowGaps(_ s: Subviews, _ c: Cache) -> [CGFloat] {
        guard c.rowCount > 1 else { return [] }
        return (0..<(c.rowCount - 1)).map { i in
            if let v = verticalSpacing { return v }
            var above = ViewSpacing.zero, below = ViewSpacing.zero
            for cell in c.cells {
                if cell.row == i { above.formUnion(s[cell.subview].spacing, edges: .bottom) }
                if cell.row == i + 1 { below.formUnion(s[cell.subview].spacing, edges: .top) }
            }
            return above.distance(to: below, along: .vertical)
        }
    }

    private struct Arrangement {
        var widths: [CGFloat]
        var heights: [CGFloat]
        var colGaps: [CGFloat]
        var rowGaps: [CGFloat]
        var size: CGSize

        func x(_ col: Int) -> CGFloat { (0..<col).reduce(0) { $0 + widths[$1] + colGaps[$1] } }
        func y(_ row: Int) -> CGFloat { (0..<row).reduce(0) { $0 + heights[$1] + rowGaps[$1] } }
        func width(_ col: Int, span: Int) -> CGFloat {
            (col..<(col + span)).reduce(0) { $0 + widths[$1] } + (col..<(col + span - 1)).reduce(0) { $0 + colGaps[$1] }
        }
    }

    private func arrange(_ p: ProposedViewSize, _ s: Subviews, _ c: Cache) -> Arrangement {
        let colGaps = columnGaps(s, c), rowGaps = rowGaps(s, c)
        // Columns, from single-column cells.
        let singles = (0..<c.columnCount).map { j in c.cells.filter { $0.column == j && $0.span == 1 } }
        func columnWidth(_ j: Int, _ offer: CGFloat?) -> CGFloat {
            singles[j].map { s[$0.subview].node.length(along: .horizontal, ProposedViewSize(width: offer, height: nil)) }.max() ?? 0
        }
        var widths: [CGFloat]
        if let w = p.width {
            let items = (0..<c.columnCount).map { j in
                DistributionItem(minLength: columnWidth(j, 0), maxLength: columnWidth(j, .infinity), priority: 0,
                                 measure: { columnWidth(j, $0) })
            }
            widths = distribute(w - colGaps.reduce(0, +), items).map(\.length)
        } else {
            widths = (0..<c.columnCount).map { columnWidth($0, nil) }
        }
        var a = Arrangement(widths: widths, heights: [], colGaps: colGaps, rowGaps: rowGaps, size: .zero)
        // Rows, with each cell offered its column width.
        let rows = (0..<c.rowCount).map { i in c.cells.filter { $0.row == i } }
        func rowHeight(_ i: Int, _ offer: CGFloat?) -> CGFloat {
            rows[i].map { cell in
                s[cell.subview].node.length(along: .vertical,
                                            ProposedViewSize(width: a.width(cell.column, span: cell.span), height: offer))
            }.max() ?? 0
        }
        if let h = p.height {
            let items = (0..<c.rowCount).map { i in
                DistributionItem(minLength: rowHeight(i, 0), maxLength: rowHeight(i, .infinity), priority: 0,
                                 measure: { rowHeight(i, $0) })
            }
            a.heights = distribute(h - rowGaps.reduce(0, +), items).map(\.length)
        } else {
            a.heights = (0..<c.rowCount).map { rowHeight($0, nil) }
        }
        a.size = CGSize(width: a.widths.reduce(0, +) + colGaps.reduce(0, +),
                        height: a.heights.reduce(0, +) + rowGaps.reduce(0, +))
        if c.cells.isEmpty { a.size = .zero }
        return a
    }

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        arrange(proposal, subviews, cache).size
    }

    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        let a = arrange(proposal, subviews, cache)
        for row in 0..<cache.rowCount {
            let cells = cache.cells.filter { $0.row == row }
            let vKey = (cells.first?.rowAlignment ?? alignment.vertical).key
            let props = cells.map { ProposedViewSize(width: a.width($0.column, span: $0.span), height: a.heights[row]) }
            let dims = zip(cells, props).map { subviews[$0.subview].dimensions(in: $1) }
            // Within the row, cells line up on the row's vertical guide.
            let guides = dims.map { $0[key: vKey] }
            let before = guides.max() ?? 0
            let extent = before + (zip(guides, dims).map { $1.height - $0 }.max() ?? 0)
            let unit = Swift.min(Swift.max(vKey.defaultValue(for: CGSize(width: 1, height: 1)), 0), 1)
            let top = bounds.minY + a.y(row) + (a.heights[row] - extent) * unit
            for (k, cell) in cells.enumerated() {
                let cw = a.width(cell.column, span: cell.span)
                let hKey = alignment.horizontal.key
                let x = bounds.minX + a.x(cell.column) + hKey.defaultValue(for: CGSize(width: cw, height: 0)) - dims[k][key: hKey]
                subviews[cell.subview].place(at: CGPoint(x: x, y: top + before - guides[k]), anchor: .topLeading,
                                             proposal: props[k])
            }
        }
    }
}

/// The content of a grid: a row of cells, or a single view taking a row.
package enum GridContent {
    case row(alignment: VerticalAlignment?, cells: [LayoutNode])
    case single(LayoutNode)
}

extension LayoutNode {
    /// A `Grid`. Cells are tagged with their row so that `GridLayout` can
    /// rebuild the structure from its (flat) subviews.
    package static func grid(alignment: Alignment = .center, horizontalSpacing: CGFloat? = nil,
                             verticalSpacing: CGFloat? = nil, _ content: [GridContent]) -> LayoutNode {
        var cells: [LayoutNode] = []
        for (r, item) in content.enumerated() {
            switch item {
            case .row(let a, let row):
                for c in row {
                    var n = c.layoutValue(key: GridRowIndexKey.self, value: r)
                    if let a { n = n.layoutValue(key: GridRowAlignmentKey.self, value: a) }
                    cells.append(n)
                }
            case .single(let n):
                cells.append(n.layoutValue(key: GridRowIndexKey.self, value: r).layoutValue(key: GridFullRowKey.self, value: true))
            }
        }
        return layout(GridLayout(alignment: alignment, horizontalSpacing: horizontalSpacing, verticalSpacing: verticalSpacing), cells)
    }

    /// `gridCellColumns(_:)`.
    package func gridCellColumns(_ n: Int) -> LayoutNode { layoutValue(key: GridCellColumnsKey.self, value: n) }
}
