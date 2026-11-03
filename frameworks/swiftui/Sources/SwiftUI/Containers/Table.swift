import Foundation
#if OPENVIEWS_RENAMED
import OpenViewsCore
#else
import SwiftUICore
#endif

// Tables (round R13, left over from R9 / PARITY §5.4 R12; public API names:
// `Table`, `TableColumn`, `TableColumnBuilder`, `TableColumnContent`,
// `width(_:)`, `width(min:ideal:max:)`, `KeyPathComparator` sort orders).
//
// As the public documentation describes: a table shows one row per element
// of its data and one column per `TableColumn`; it does not sort the data
// itself. Clicking a sortable column's header writes the table's
// `sortOrder` binding (that column's comparator first; clicking the first
// column again reverses its order), and the app sorts its data when the
// binding changes. Selection works as in `List` (one or several rows, by
// the elements' IDs; click, Shift and Ctrl, the arrow keys).
//
// Look and widths (Ycode's): a 28-point header row with the titles in
// footnote weight, the first sort column's chevron, and a divider between
// columns; 24-point rows with alternating backgrounds. A column with a fixed
// width keeps it; the others share what is left, within their minimums and
// maximums (default minimum 40). Dragging a header divider resizes the
// column on its left (the columns after it keep their widths; the last
// flexible column takes up the difference).

// MARK: - Columns

/// One column of a table as the table uses it.
public struct _TableColumnSpec<RowValue> {
    let id: Int
    let label: AnyView
    let cell: (RowValue) -> AnyView
    /// The comparator a header click puts first (nil: not sortable).
    let comparator: KeyPathComparator<RowValue>?
    var width: TableColumnWidth
}

/// How wide a column is.
public struct TableColumnWidth: Equatable, Sendable {
    var fixed: CGFloat?
    var min: CGFloat?
    var ideal: CGFloat?
    var max: CGFloat?
    static let flexible = TableColumnWidth()
}

/// Columns of a table: `TableColumn`s, or a group of them from a builder.
@MainActor @preconcurrency
public protocol TableColumnContent {
    associatedtype TableRowValue
    var _tableColumns: [_TableColumnSpec<TableRowValue>] { get }
}

/// Several columns.
public struct TupleTableColumnContent<RowValue>: TableColumnContent {
    public typealias TableRowValue = RowValue
    let columns: [_TableColumnSpec<RowValue>]
    public var _tableColumns: [_TableColumnSpec<RowValue>] { columns }
}

/// Builds a table's columns.
@MainActor @resultBuilder
public struct TableColumnBuilder<RowValue> {
    public static func buildExpression<C: TableColumnContent>(_ column: C) -> TupleTableColumnContent<RowValue>
        where C.TableRowValue == RowValue {
        TupleTableColumnContent(columns: column._tableColumns)
    }

    public static func buildBlock(_ parts: TupleTableColumnContent<RowValue>...) -> TupleTableColumnContent<RowValue> {
        TupleTableColumnContent(columns: parts.flatMap(\.columns))
    }

    public static func buildOptional(_ part: TupleTableColumnContent<RowValue>?) -> TupleTableColumnContent<RowValue> {
        part ?? TupleTableColumnContent(columns: [])
    }

    public static func buildEither(first: TupleTableColumnContent<RowValue>) -> TupleTableColumnContent<RowValue> { first }
    public static func buildEither(second: TupleTableColumnContent<RowValue>) -> TupleTableColumnContent<RowValue> { second }
    public static func buildLimitedAvailability(_ part: TupleTableColumnContent<RowValue>) -> TupleTableColumnContent<RowValue> { part }
}

/// One column: a title and a cell per row; sortable when it has a
/// comparator (`Sort` is `KeyPathComparator<RowValue>`, else `Never`).
public struct TableColumn<RowValue, Sort, Content: View, Label: View>: TableColumnContent {
    public typealias TableRowValue = RowValue
    let label: Label
    let content: (RowValue) -> Content
    let comparator: KeyPathComparator<RowValue>?
    var width = TableColumnWidth.flexible

    public var _tableColumns: [_TableColumnSpec<RowValue>] {
        let content = content
        return [_TableColumnSpec(id: 0, label: AnyView(label), cell: { AnyView(content($0)) }, comparator: comparator,
                                 width: width)]
    }

    /// A fixed width (nil: flexible).
    public func width(_ width: CGFloat?) -> TableColumn {
        var c = self
        c.width = width.map { TableColumnWidth(fixed: $0) } ?? .flexible
        return c
    }

    public func width(min: CGFloat? = nil, ideal: CGFloat? = nil, max: CGFloat? = nil) -> TableColumn {
        var c = self
        c.width = TableColumnWidth(fixed: nil, min: min, ideal: ideal, max: max)
        return c
    }
}

extension TableColumn where Sort == Never, Label == Text {
    /// A column that is not sortable.
    public init(_ titleKey: LocalizedStringKey, @ViewBuilder content: @escaping (RowValue) -> Content) {
        label = Text(titleKey)
        self.content = content
        comparator = nil
    }

    @_disfavoredOverload
    public init<S: StringProtocol>(_ title: S, @ViewBuilder content: @escaping (RowValue) -> Content) {
        label = Text(title)
        self.content = content
        comparator = nil
    }
}

extension TableColumn where Sort == KeyPathComparator<RowValue>, Label == Text {
    /// A column sorted by a comparable property, with its own cells.
    public init<V: Comparable>(_ titleKey: LocalizedStringKey, value: any KeyPath<RowValue, V> & Sendable,
                               @ViewBuilder content: @escaping (RowValue) -> Content) {
        label = Text(titleKey)
        self.content = content
        comparator = KeyPathComparator(value)
    }

    @_disfavoredOverload
    public init<S: StringProtocol, V: Comparable>(_ title: S, value: any KeyPath<RowValue, V> & Sendable,
                                                  @ViewBuilder content: @escaping (RowValue) -> Content) {
        label = Text(title)
        self.content = content
        comparator = KeyPathComparator(value)
    }

    /// A column sorted with `comparator`.
    public init(_ titleKey: LocalizedStringKey, sortUsing comparator: KeyPathComparator<RowValue>,
                @ViewBuilder content: @escaping (RowValue) -> Content) {
        label = Text(titleKey)
        self.content = content
        self.comparator = comparator
    }
}

extension TableColumn where Sort == KeyPathComparator<RowValue>, Content == Text, Label == Text {
    /// A column showing and sorted by a string property.
    public init(_ titleKey: LocalizedStringKey, value: any KeyPath<RowValue, String> & Sendable) {
        label = Text(titleKey)
        let kp = UncheckedTableKeyPath(value)
        content = { Text(verbatim: $0[keyPath: kp.value]) }
        comparator = KeyPathComparator(value)
    }

    @_disfavoredOverload
    public init<S: StringProtocol>(_ title: S, value: any KeyPath<RowValue, String> & Sendable) {
        label = Text(title)
        let kp = UncheckedTableKeyPath(value)
        content = { Text(verbatim: $0[keyPath: kp.value]) }
        comparator = KeyPathComparator(value)
    }
}

private struct UncheckedTableKeyPath<Root, Value>: @unchecked Sendable {
    let value: KeyPath<Root, Value>
    init(_ v: KeyPath<Root, Value>) { value = v }
}

// MARK: - Table

enum TableMetrics {
    static let headerHeight: CGFloat = 28
    static let rowHeight: CGFloat = 24
    static let cellPadding: CGFloat = 8
    static let defaultMinimum: CGFloat = 40
    static let handleWidth: CGFloat = 8
}

/// Rows of data in columns.
public struct Table<Value: Identifiable, Columns: TableColumnContent>: View where Columns.TableRowValue == Value {
    let rows: [Value]
    let columns: [_TableColumnSpec<Value>]
    let selection: TableSelection
    let sortOrder: Binding<[KeyPathComparator<Value>]>?
    /// Widths the user set by dragging (nil: from the column specs).
    @State private var widths: [CGFloat]?
    @State private var dragBase: [CGFloat]?
    @Environment(\.colorScheme) private var scheme

    enum TableSelection {
        case none
        case single(Binding<Value.ID?>)
        case multiple(Binding<Set<Value.ID>>)
    }

    init<Data: RandomAccessCollection>(data: Data, selection: TableSelection, sortOrder: Binding<[KeyPathComparator<Value>]>?,
                                       columns: Columns) where Data.Element == Value {
        rows = Array(data)
        var cols = columns._tableColumns
        for i in cols.indices { cols[i] = _TableColumnSpec(id: i, label: cols[i].label, cell: cols[i].cell,
                                                           comparator: cols[i].comparator, width: cols[i].width) }
        self.columns = cols
        self.selection = selection
        self.sortOrder = sortOrder
    }

    /// The widths for a total width: fixed columns keep theirs, the others
    /// share the rest (ideal widths first), within their limits.
    static func layout(_ columns: [_TableColumnSpec<Value>], total: CGFloat, current: [CGFloat]?) -> [CGFloat] {
        if let current, current.count == columns.count, !current.isEmpty {
            // Keep the user's widths; the last flexible column takes up the
            // difference.
            var w = current
            let sum = w.reduce(0, +)
            if let last = columns.lastIndex(where: { $0.width.fixed == nil }) {
                let lo = columns[last].width.min ?? TableMetrics.defaultMinimum
                w[last] = max(lo, w[last] + total - sum)
            }
            return w
        }
        var w = columns.map { $0.width.fixed ?? $0.width.ideal ?? 0 }
        let flexible = columns.indices.filter { columns[$0].width.fixed == nil && columns[$0].width.ideal == nil }
        let used = w.reduce(0, +)
        if !flexible.isEmpty {
            let share = max(0, total - used) / CGFloat(flexible.count)
            for i in flexible { w[i] = share }
        }
        for i in columns.indices {
            let c = columns[i].width
            if c.fixed == nil {
                w[i] = Swift.max(c.min ?? TableMetrics.defaultMinimum, Swift.min(c.max ?? .infinity, w[i]))
            }
        }
        return w
    }

    private func sort(by column: _TableColumnSpec<Value>) {
        guard let sortOrder, var c = column.comparator else { return }
        var order = sortOrder.wrappedValue
        if let first = order.first, first.keyPath == c.keyPath {
            order[0].order = first.order == .forward ? .reverse : .forward
        } else {
            order.removeAll { $0.keyPath == c.keyPath }
            c.order = .forward
            order.insert(c, at: 0)
        }
        sortOrder.wrappedValue = order
    }

    public var body: some View {
        GeometryReader { proxy in
            let w = Self.layout(columns, total: proxy.size.width, current: widths)
            VStack(spacing: 0) {
                header(w)
                Divider()
                rowsList(w)
            }
        }
    }

    private func header(_ w: [CGFloat]) -> some View {
        let palette = ControlPalette(scheme)
        let first = sortOrder?.wrappedValue.first
        return HStack(spacing: 0) {
            ForEach(columns, id: \.id) { col in
                let i = col.id
                let sorted = first != nil && col.comparator?.keyPath == first?.keyPath
                HStack(spacing: 4) {
                    col.label.font(.footnote.weight(.semibold)).lineLimit(1)
                    Spacer(minLength: 0)
                    if sorted {
                        Image(systemName: first?.order == .reverse ? "chevron.down" : "chevron.up")
                            .resizable().frame(width: 8, height: 5).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, TableMetrics.cellPadding)
                .frame(width: max(0, i < w.count ? w[i] : 0), height: TableMetrics.headerHeight, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { sort(by: col) }
                .overlay(alignment: .trailing) {
                    Rectangle().fill(palette.separator).frame(width: 1, height: 16)
                        .frame(width: TableMetrics.handleWidth, height: TableMetrics.headerHeight)
                        .contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 1)
                            .onChanged { v in resize(i, by: v.translation.width, from: w) }
                            .onEnded { _ in dragBase = nil })
                        .offset(x: TableMetrics.handleWidth / 2)
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("table header \(i)")
            }
            Spacer(minLength: 0)
        }
        .frame(height: TableMetrics.headerHeight)
        .background(palette.barBackground)
    }

    private func resize(_ i: Int, by dx: CGFloat, from current: [CGFloat]) {
        let base = dragBase ?? current
        if dragBase == nil { dragBase = current }
        guard i < base.count, columns[i].width.fixed == nil || true else { return }
        let c = columns[i].width
        var w = base
        w[i] = max(c.min ?? TableMetrics.defaultMinimum, min(c.max ?? .infinity, base[i] + dx))
        widths = w
    }

    @ViewBuilder
    private func rowsList(_ w: [CGFloat]) -> some View {
        let palette = ControlPalette(scheme)
        let content = ForEach(Array(rows.enumerated()), id: \.element.id) { pair in
            HStack(spacing: 0) {
                ForEach(columns, id: \.id) { col in
                    col.cell(pair.element)
                        .lineLimit(1)
                        .padding(.horizontal, TableMetrics.cellPadding)
                        .frame(width: max(0, col.id < w.count ? w[col.id] : 0), alignment: .leading)
                }
                Spacer(minLength: 0)
            }
            .frame(minHeight: TableMetrics.rowHeight)
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
            .listRowBackground(pair.offset % 2 == 1 ? palette.fill.opacity(0.35) : Color.clear)
            .tag(pair.element.id)
        }
        Group {
            switch selection {
            case .none: List { content }
            case .single(let b): List(selection: b) { content }
            case .multiple(let b): List(selection: b) { content }
            }
        }
        .listStyle(.plain)
        .environment(\.defaultMinListRowHeight, TableMetrics.rowHeight)
    }
}

extension Table {
    public init<Data: RandomAccessCollection>(_ data: Data, @TableColumnBuilder<Value> columns: () -> Columns)
        where Data.Element == Value {
        self.init(data: data, selection: .none, sortOrder: nil, columns: columns())
    }

    public init<Data: RandomAccessCollection>(_ data: Data, selection: Binding<Value.ID?>,
                                              @TableColumnBuilder<Value> columns: () -> Columns) where Data.Element == Value {
        self.init(data: data, selection: .single(selection), sortOrder: nil, columns: columns())
    }

    public init<Data: RandomAccessCollection>(_ data: Data, selection: Binding<Set<Value.ID>>,
                                              @TableColumnBuilder<Value> columns: () -> Columns) where Data.Element == Value {
        self.init(data: data, selection: .multiple(selection), sortOrder: nil, columns: columns())
    }

    public init<Data: RandomAccessCollection>(_ data: Data, sortOrder: Binding<[KeyPathComparator<Value>]>,
                                              @TableColumnBuilder<Value> columns: () -> Columns) where Data.Element == Value {
        self.init(data: data, selection: .none, sortOrder: sortOrder, columns: columns())
    }

    public init<Data: RandomAccessCollection>(_ data: Data, selection: Binding<Value.ID?>,
                                              sortOrder: Binding<[KeyPathComparator<Value>]>,
                                              @TableColumnBuilder<Value> columns: () -> Columns) where Data.Element == Value {
        self.init(data: data, selection: .single(selection), sortOrder: sortOrder, columns: columns())
    }

    public init<Data: RandomAccessCollection>(_ data: Data, selection: Binding<Set<Value.ID>>,
                                              sortOrder: Binding<[KeyPathComparator<Value>]>,
                                              @TableColumnBuilder<Value> columns: () -> Columns) where Data.Element == Value {
        self.init(data: data, selection: .multiple(selection), sortOrder: sortOrder, columns: columns())
    }
}
